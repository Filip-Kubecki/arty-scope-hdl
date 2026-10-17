#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scope_app.py - GUI do płytki przez protokół TCP (port 5000).

Funkcje:
  - połączenie z płytką i rozłączenie
  - odczyt stanu akwizycji i numeru rekordu (opcjonalnie auto co 1 s)
  - ręczne STOP, ARM, FORCE_TRIGGER
  - konfiguracja: długość, maska kanałów, pre-trigger, źródło, krawędź,
    poziom, histereza (wczytaj z płytki, zatwierdź, domyślne)
  - cykl ręczny: ARM -> FORCE -> READY -> odczyt
  - cykl z poziomem: ARM -> czekaj na READY (bez FORCE) -> odczyt
  - odczyt rekordu z wykresem i zaznaczeniem pozycji wyzwolenia
  - kontrola zgodności pozycji wyzwolenia z przejściem przez poziom
    (tylko dla rekordów z cyklu z poziomem)
  - kontrola wskaźników: (trigger - write) mod N == pre
    (tylko dla cyklu z poziomem)
  - zapis rekordu do .bin albo .csv

Wymagania: python3, tkinter, matplotlib.
  sudo apt install python3-tk     (jeśli brak tkinter)

Uruchomienie z katalogu repo:
    python3 tools/scope_app.py
"""

import queue
import socket
import struct
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, ttk

import matplotlib

matplotlib.use("TkAgg")
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
from matplotlib.figure import Figure


MAGIC = b"\xc7\xe2"
CMD_WRITE = 0x01
CMD_READ = 0x02
RSP_WRITE = 0x81
RSP_READ = 0x82
RSP_ERROR = 0xFF
RECORD_TYPE = 0xD0
HDR_LEN = 64
RECORD_MAX_SAMPLES = 8192

# Akwizycja
ADDR_STATE = 0xA0
ADDR_RECORD_ID = 0xA4
ADDR_ARM = 0x11
ADDR_STOP = 0x12
ADDR_FORCE = 0x13
ADDR_READ_RECORD = 0x17
ADDR_WRITE_POINTER = 0xA1
ADDR_TRIGGER_POINTER = 0xA2

# Konfiguracja
ADDR_COMMIT = 0x10
ADDR_RESET_CONFIG = 0x16
ADDR_RECORD_LENGTH = 0x31
ADDR_CHANNEL_MASK = 0x34
ADDR_PRETRIGGER = 0x32
ADDR_TRIGGER_SOURCE = 0x40
ADDR_TRIGGER_EDGE = 0x41
ADDR_TRIGGER_LEVEL = 0x42
ADDR_TRIGGER_HYSTERESIS = 0x43

ST_IDLE, ST_ARMED, ST_CAPTURE, ST_READY = 0x00, 0x01, 0x02, 0x03
STATE_NAMES = {
    ST_IDLE: "IDLE",
    ST_ARMED: "ARMED",
    ST_CAPTURE: "CAPTURE",
    ST_READY: "READY",
}
ERROR_NAMES = {
    0x01: "ERROR_UNKNOWN_COMMAND",
    0x02: "ERROR_BAD_ADDRESS",
    0x03: "ERROR_READ_ONLY",
    0x04: "ERROR_WRITE_ONLY",
    0x05: "ERROR_BAD_VALUE",
    0x06: "ERROR_NOT_READY",
}

MASK_OPTIONS = {"01 (ch1)": 0x01, "02 (ch2)": 0x02, "03 (ch1 + ch2)": 0x03}
SOURCE_OPTIONS = {"ch1 (0)": 0x00, "ch2 (1)": 0x01}
EDGE_OPTIONS = {"narastająca (0)": 0x00, "opadająca (1)": 0x01, "obie (2)": 0x02}


def option_label(options, value):
    for label, v in options.items():
        if v == value:
            return label
    return next(iter(options))


class ProtocolError(Exception):
    pass


def check_response(resp, label):
    if resp[2] == RSP_ERROR:
        code = resp[7]
        name = ERROR_NAMES.get(code, f"kod {code:#04x}")
        raise ProtocolError(f"{label}: {name}")
    return resp


class Device:
    """Połączenie TCP i ramki protokołu. Jedna operacja naraz (lock)."""

    def __init__(self):
        self.sock = None
        self.lock = threading.Lock()

    def connect(self, host, port):
        self.close()
        self.sock = socket.create_connection((host, port), timeout=5)

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def _recv(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ProtocolError("połączenie zamknięte przez płytkę")
            buf.extend(chunk)
        return bytes(buf)

    def _request(self, cmd, addr, data=0):
        if self.sock is None:
            raise ProtocolError("brak połączenia")
        self.sock.sendall(MAGIC + bytes([cmd, addr]) + struct.pack(">I", data))
        resp = self._recv(8)
        if resp[:2] != MAGIC:
            raise ProtocolError(f"zły magic w odpowiedzi: {resp.hex(' ')}")
        return resp

    def request(self, cmd, addr, data=0):
        with self.lock:
            return self._request(cmd, addr, data)

    def read_record(self):
        """READ_RECORD + nagłówek + próbki. Zwraca (info, payload)."""
        with self.lock:
            resp = self._request(CMD_WRITE, ADDR_READ_RECORD)
            check_response(resp, "READ_RECORD")
            if resp[2] != RSP_WRITE:
                raise ProtocolError(f"nieoczekiwana odpowiedź: {resp.hex(' ')}")

            hdr = self._recv(HDR_LEN)
            if hdr[:2] != MAGIC or hdr[2] != RECORD_TYPE:
                raise ProtocolError(f"zły nagłówek bloku: {hdr[:4].hex(' ')}")

            info = {
                "plen": struct.unpack(">I", hdr[4:8])[0],
                "rid": struct.unpack(">I", hdr[8:12])[0],
                "mask": hdr[12],
                "sbits": hdr[13],
                "samples": struct.unpack(">I", hdr[16:20])[0],
                "trigger_pos": struct.unpack(">I", hdr[20:24])[0],
            }
            if info["mask"] == 0:
                expected = 0
            else:
                nch = 2 if info["mask"] == 0x03 else 1
                expected = info["samples"] * nch * info["sbits"] // 8
            if info["plen"] != expected:
                raise ProtocolError(
                    f"PAYLOAD_LEN {info['plen']} != oczekiwane {expected}"
                )

            payload = self._recv(info["plen"]) if info["plen"] else b""
            return info, payload


class Worker(threading.Thread):
    """Wykonuje zadania po kolei, żeby nie blokować GUI i nie mieszać ramek."""

    def __init__(self, tasks, results):
        super().__init__(daemon=True)
        self.tasks = tasks
        self.results = results

    def run(self):
        while True:
            name, fn, args = self.tasks.get()
            try:
                self.results.put((name, True, fn(*args)))
            except Exception as exc:
                self.results.put((name, False, str(exc)))


RECORD_TASKS = ("read", "cycle_manual", "cycle_level")


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("arty-scope: sterowanie")
        self.geometry("1150x880")

        self.dev = Device()
        self.tasks = queue.Queue()
        self.results = queue.Queue()
        self.worker = Worker(self.tasks, self.results)
        self.worker.start()

        self.last_info = None
        self.last_payload = None
        # konfiguracja zatwierdzona (COMMIT) w tej sesji; None, dopóki nie zatwierdzisz
        self.applied_cfg = None
        self.pending_cfg = None  # konfiguracja wysłana w ostatnim zatwierdzeniu

        self._build_ui()
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.after(100, self.poll_results)
        self.after(1000, self.auto_tick)
        self.set_connected(False)

    # ------------------------------------------------------------------ UI

    def _build_ui(self):
        top = ttk.Frame(self, padding=8)
        top.pack(fill="x")

        self.host_var = tk.StringVar(value="192.168.1.50")
        self.port_var = tk.StringVar(value="5000")

        ttk.Label(top, text="Host").pack(side="left")
        ttk.Entry(top, textvariable=self.host_var, width=16).pack(side="left", padx=4)
        ttk.Label(top, text="Port").pack(side="left")
        ttk.Entry(top, textvariable=self.port_var, width=6).pack(side="left", padx=4)

        self.btn_connect = ttk.Button(top, text="Połącz", command=self.on_connect)
        self.btn_connect.pack(side="left", padx=4)
        self.btn_disconnect = ttk.Button(
            top, text="Rozłącz", command=self.on_disconnect
        )
        self.btn_disconnect.pack(side="left", padx=4)

        self.conn_label = ttk.Label(top, text="rozłączono", foreground="gray")
        self.conn_label.pack(side="left", padx=12)

        # Sterowanie akwizycją
        ctl = ttk.LabelFrame(self, text="Sterowanie", padding=8)
        ctl.pack(fill="x", padx=8, pady=4)

        self.btn_stop = ttk.Button(
            ctl, text="STOP", command=lambda: self.on_cmd(ADDR_STOP, "STOP")
        )
        self.btn_arm = ttk.Button(
            ctl, text="ARM", command=lambda: self.on_cmd(ADDR_ARM, "ARM")
        )
        self.btn_force = ttk.Button(
            ctl,
            text="FORCE_TRIGGER",
            command=lambda: self.on_cmd(ADDR_FORCE, "FORCE_TRIGGER"),
        )
        self.btn_read = ttk.Button(ctl, text="Odczytaj rekord", command=self.on_read)
        self.btn_cycle_manual = ttk.Button(
            ctl,
            text="Cykl ręczny: ARM -> FORCE -> READY -> odczyt",
            command=self.on_cycle_manual,
        )
        self.btn_cycle_trigger = ttk.Button(
            ctl,
            text="Cykl z poziomem: ARM -> READY -> odczyt",
            command=self.on_cycle_trigger,
        )
        self.control_buttons = [
            self.btn_stop,
            self.btn_arm,
            self.btn_force,
            self.btn_read,
            self.btn_cycle_manual,
            self.btn_cycle_trigger,
        ]
        for b in self.control_buttons:
            b.pack(side="left", padx=4)

        # Konfiguracja
        cfg = ttk.LabelFrame(
            self, text="Konfiguracja (zatwierdzana przez COMMIT w IDLE)", padding=8
        )
        cfg.pack(fill="x", padx=8, pady=4)

        self.var_record_length = tk.StringVar(value="8192")
        self.var_pre = tk.StringVar(value="0")
        self.var_level = tk.StringVar(value="128")
        self.var_hyst = tk.StringVar(value="0")
        self.var_mask = tk.StringVar(value=option_label(MASK_OPTIONS, 0x01))
        self.var_source = tk.StringVar(value=option_label(SOURCE_OPTIONS, 0x00))
        self.var_edge = tk.StringVar(value=option_label(EDGE_OPTIONS, 0x00))

        row1 = ttk.Frame(cfg)
        row1.pack(fill="x", pady=2)
        ttk.Label(row1, text="Długość [próbki]:", width=18).pack(side="left")
        self.entry_record_length = ttk.Entry(
            row1, textvariable=self.var_record_length, width=8
        )
        self.entry_record_length.pack(side="left", padx=4)
        ttk.Label(row1, text="Pre-trigger [próbki]:", width=18).pack(
            side="left", padx=(12, 0)
        )
        self.entry_pre = ttk.Entry(row1, textvariable=self.var_pre, width=8)
        self.entry_pre.pack(side="left", padx=4)
        ttk.Label(row1, text="Maska kanałów:", width=14).pack(side="left", padx=(12, 0))
        self.combo_mask = ttk.Combobox(
            row1,
            textvariable=self.var_mask,
            values=list(MASK_OPTIONS),
            state="readonly",
            width=14,
        )
        self.combo_mask.pack(side="left", padx=4)

        row2 = ttk.Frame(cfg)
        row2.pack(fill="x", pady=2)
        ttk.Label(row2, text="Źródło wyzwalania:", width=18).pack(side="left")
        self.combo_source = ttk.Combobox(
            row2,
            textvariable=self.var_source,
            values=list(SOURCE_OPTIONS),
            state="readonly",
            width=12,
        )
        self.combo_source.pack(side="left", padx=4)
        ttk.Label(row2, text="Krawędź:", width=18).pack(side="left", padx=(12, 0))
        self.combo_edge = ttk.Combobox(
            row2,
            textvariable=self.var_edge,
            values=list(EDGE_OPTIONS),
            state="readonly",
            width=16,
        )
        self.combo_edge.pack(side="left", padx=4)

        row3 = ttk.Frame(cfg)
        row3.pack(fill="x", pady=2)
        ttk.Label(row3, text="Poziom [kod 0-255]:", width=18).pack(side="left")
        self.entry_level = ttk.Entry(row3, textvariable=self.var_level, width=8)
        self.entry_level.pack(side="left", padx=4)
        ttk.Label(row3, text="Histereza [kod 0-255]:", width=18).pack(
            side="left", padx=(12, 0)
        )
        self.entry_hyst = ttk.Entry(row3, textvariable=self.var_hyst, width=8)
        self.entry_hyst.pack(side="left", padx=4)

        row4 = ttk.Frame(cfg)
        row4.pack(fill="x", pady=(6, 0))
        self.btn_cfg_read = ttk.Button(
            row4, text="Wczytaj z płytki", command=self.on_config_read
        )
        self.btn_cfg_apply = ttk.Button(
            row4, text="Zatwierdź (STOP, zapis, COMMIT)", command=self.on_config_apply
        )
        self.btn_cfg_reset = ttk.Button(
            row4, text="Domyślne (RESET_CONFIG)", command=self.on_config_reset
        )
        for b in (self.btn_cfg_read, self.btn_cfg_apply, self.btn_cfg_reset):
            b.pack(side="left", padx=4)

        self.cfg_widgets = [
            self.entry_record_length,
            self.entry_pre,
            self.combo_mask,
            self.combo_source,
            self.combo_edge,
            self.entry_level,
            self.entry_hyst,
            self.btn_cfg_read,
            self.btn_cfg_apply,
            self.btn_cfg_reset,
        ]
        self.cfg_combos = (self.combo_mask, self.combo_source, self.combo_edge)

        # Stan i rekord
        st = ttk.LabelFrame(self, text="Stan i rekord", padding=8)
        st.pack(fill="x", padx=8, pady=4)

        self.state_var = tk.StringVar(value="-")
        self.rid_var = tk.StringVar(value="-")
        self.vref_var = tk.StringVar(value="4.1")
        self.auto_var = tk.BooleanVar(value=False)

        ttk.Label(st, text="Stan:").pack(side="left")
        ttk.Label(st, textvariable=self.state_var, width=18).pack(side="left", padx=4)
        ttk.Label(st, text="RECORD_ID:").pack(side="left")
        ttk.Label(st, textvariable=self.rid_var, width=8).pack(side="left", padx=4)

        self.btn_status = ttk.Button(st, text="Odśwież stan", command=self.on_status)
        self.btn_status.pack(side="left", padx=4)
        self.chk_auto = ttk.Checkbutton(st, text="auto co 1 s", variable=self.auto_var)
        self.chk_auto.pack(side="left", padx=4)

        ttk.Label(st, text="Vref [V]:").pack(side="left", padx=(16, 0))
        ttk.Entry(st, textvariable=self.vref_var, width=6).pack(side="left", padx=4)

        self.btn_save = ttk.Button(st, text="Zapisz rekord...", command=self.on_save)
        self.btn_save.pack(side="left", padx=16)

        self.fig = Figure(figsize=(9, 4), dpi=100)
        self.ax = self.fig.add_subplot(111)
        self.ax.set_xlabel("próbka")
        self.ax.set_ylabel("napięcie [V] (przybliżone)")
        self.ax.grid(True, alpha=0.3)
        self.canvas = FigureCanvasTkAgg(self.fig, master=self)
        self.canvas.get_tk_widget().pack(fill="both", expand=True, padx=8, pady=4)

        self.log_text = scrolledtext.ScrolledText(self, height=8, state="disabled")
        self.log_text.pack(fill="x", padx=8, pady=(0, 8))

    def log(self, msg):
        ts = time.strftime("%H:%M:%S")
        self.log_text.configure(state="normal")
        self.log_text.insert("end", f"[{ts}] {msg}\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def set_connected(self, flag):
        self.btn_connect.configure(state="disabled" if flag else "normal")
        self.btn_disconnect.configure(state="normal" if flag else "disabled")
        self.conn_label.configure(
            text="połączono" if flag else "rozłączono",
            foreground="green" if flag else "gray",
        )
        for b in self.control_buttons:
            b.configure(state="normal" if flag else "disabled")
        for w in self.cfg_widgets:
            if not flag:
                state = "disabled"
            elif w in self.cfg_combos:
                state = "readonly"
            else:
                state = "normal"
            w.configure(state=state)
        self.btn_status.configure(state="normal" if flag else "disabled")
        self.btn_save.configure(state="normal" if flag else "disabled")

    # ------------------------------------------------------- zadania (wątek)

    def submit(self, name, fn, *args):
        self.tasks.put((name, fn, args))

    def t_connect(self, host, port):
        self.dev.connect(host, port)
        return f"połączono z {host}:{port}"

    def t_disconnect(self):
        self.dev.close()
        return "rozłączono"

    def t_status(self):
        st = check_response(self.dev.request(CMD_READ, ADDR_STATE), "STATE")[7]
        rid_resp = check_response(
            self.dev.request(CMD_READ, ADDR_RECORD_ID), "RECORD_ID"
        )
        rid = struct.unpack(">I", rid_resp[4:8])[0]
        return st, rid

    def t_command(self, addr, label):
        check_response(self.dev.request(CMD_WRITE, addr), label)
        return label

    def t_write(self, addr, value, label):
        resp = check_response(self.dev.request(CMD_WRITE, addr, value), label)
        return struct.unpack(">I", resp[4:8])[0]

    def t_read_reg(self, addr, label):
        resp = check_response(self.dev.request(CMD_READ, addr), label)
        return struct.unpack(">I", resp[4:8])[0]

    def t_read_config(self):
        return {
            "record_length": self.t_read_reg(ADDR_RECORD_LENGTH, "RECORD_LENGTH"),
            "pre": self.t_read_reg(ADDR_PRETRIGGER, "PRETRIGGER"),
            "mask": self.t_read_reg(ADDR_CHANNEL_MASK, "CHANNEL_MASK"),
            "source": self.t_read_reg(ADDR_TRIGGER_SOURCE, "TRIGGER_SOURCE"),
            "edge": self.t_read_reg(ADDR_TRIGGER_EDGE, "TRIGGER_EDGE"),
            "level": self.t_read_reg(ADDR_TRIGGER_LEVEL, "TRIGGER_LEVEL"),
            "hyst": self.t_read_reg(ADDR_TRIGGER_HYSTERESIS, "TRIGGER_HYSTERESIS"),
        }

    def t_apply_config(self, cfg):
        # COMMIT działa tylko w IDLE, więc najpierw STOP
        self.t_command(ADDR_STOP, "STOP")
        self.t_write(ADDR_RECORD_LENGTH, cfg["record_length"], "RECORD_LENGTH")
        self.t_write(ADDR_PRETRIGGER, cfg["pre"], "PRETRIGGER")
        self.t_write(ADDR_CHANNEL_MASK, cfg["mask"], "CHANNEL_MASK")
        self.t_write(ADDR_TRIGGER_SOURCE, cfg["source"], "TRIGGER_SOURCE")
        self.t_write(ADDR_TRIGGER_EDGE, cfg["edge"], "TRIGGER_EDGE")
        self.t_write(ADDR_TRIGGER_LEVEL, cfg["level"], "TRIGGER_LEVEL")
        self.t_write(ADDR_TRIGGER_HYSTERESIS, cfg["hyst"], "TRIGGER_HYSTERESIS")
        self.t_command(ADDR_COMMIT, "COMMIT")
        return self.t_read_config()

    def t_reset_config(self):
        self.t_command(ADDR_STOP, "STOP")
        self.t_command(ADDR_RESET_CONFIG, "RESET_CONFIG")
        return self.t_read_config()

    def t_read(self):
        return self.dev.read_record()

    def t_cycle_manual(self):
        self.t_command(ADDR_ARM, "ARM")
        self.t_command(ADDR_FORCE, "FORCE_TRIGGER")
        return self._wait_ready_and_read(timeout=5.0)

    def t_cycle_trigger(self):
        self.t_command(ADDR_ARM, "ARM")
        info, payload = self._wait_ready_and_read(timeout=10.0)
        ptrs, ptr_err = self.t_read_pointers()
        return info, payload, ptrs, ptr_err

    def t_read_pointers(self):
        try:
            write_ptr = self.t_read_reg(ADDR_WRITE_POINTER, "WRITE_POINTER")
            trigger_ptr = self.t_read_reg(ADDR_TRIGGER_POINTER, "TRIGGER_POINTER")
        except ProtocolError as exc:
            return None, str(exc)
        return {"write": write_ptr, "trigger": trigger_ptr}, None

    def _wait_ready_and_read(self, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            st, _ = self.t_status()
            if st == ST_READY:
                return self.dev.read_record()
            time.sleep(0.1)
        raise ProtocolError(f"timeout: brak READY po {timeout:.0f} s")

    # --------------------------------------------------------- reakcje UI

    def on_connect(self):
        try:
            port = int(self.port_var.get())
        except ValueError:
            messagebox.showerror("Błąd", "Port musi być liczbą")
            return
        self.submit("connect", self.t_connect, self.host_var.get().strip(), port)

    def on_disconnect(self):
        self.submit("disconnect", self.t_disconnect)

    def on_cmd(self, addr, label):
        self.submit("cmd", self.t_command, addr, label)

    def on_status(self):
        self.submit("status", self.t_status)

    def on_read(self):
        self.submit("read", self.t_read)

    def on_cycle_manual(self):
        self.submit("cycle_manual", self.t_cycle_manual)

    def on_cycle_trigger(self):
        self.submit("cycle_level", self.t_cycle_trigger)

    def on_config_read(self):
        self.submit("config_read", self.t_read_config)

    def on_config_reset(self):
        if messagebox.askyesno(
            "Domyślne", "Przywrócić wartości domyślne w konfiguracji oczekującej?"
        ):
            self.submit("config_reset", self.t_reset_config)

    def on_config_apply(self):
        try:
            cfg = self._gather_config()
        except ValueError as exc:
            messagebox.showerror("Błędna konfiguracja", str(exc))
            return
        self.pending_cfg = cfg
        self.submit("config_apply", self.t_apply_config, cfg)

    def _gather_config(self):
        def int_in(text, lo, hi, label):
            try:
                value = int(text.strip(), 0)
            except ValueError:
                raise ValueError(f"{label}: podaj liczbę całkowitą")
            if not lo <= value <= hi:
                raise ValueError(f"{label}: zakres {lo}-{hi}")
            return value

        n = int_in(self.var_record_length.get(), 1, RECORD_MAX_SAMPLES, "Długość")
        pre = int_in(self.var_pre.get(), 0, RECORD_MAX_SAMPLES - 1, "Pre-trigger")
        level = int_in(self.var_level.get(), 0, 255, "Poziom")
        hyst = int_in(self.var_hyst.get(), 0, 255, "Histereza")
        if pre >= n:
            raise ValueError("Pre-trigger musi być mniejszy niż długość rekordu")

        mask = MASK_OPTIONS[self.var_mask.get()]
        source = SOURCE_OPTIONS[self.var_source.get()]
        if (source == 0x00 and not mask & 0x01) or (source == 0x01 and not mask & 0x02):
            raise ValueError("Źródło wyzwalania musi być włączone w masce kanałów")

        return {
            "record_length": n,
            "pre": pre,
            "mask": mask,
            "source": source,
            "edge": EDGE_OPTIONS[self.var_edge.get()],
            "level": level,
            "hyst": hyst,
        }

    def _show_config(self, cfg):
        self.var_record_length.set(str(cfg["record_length"]))
        self.var_pre.set(str(cfg["pre"]))
        self.var_mask.set(option_label(MASK_OPTIONS, cfg["mask"]))
        self.var_source.set(option_label(SOURCE_OPTIONS, cfg["source"]))
        self.var_edge.set(option_label(EDGE_OPTIONS, cfg["edge"]))
        self.var_level.set(str(cfg["level"]))
        self.var_hyst.set(str(cfg["hyst"]))

    def on_save(self):
        if self.last_payload is None:
            messagebox.showinfo("Brak danych", "Najpierw odczytaj rekord")
            return
        path = filedialog.asksaveasfilename(
            defaultextension=".bin",
            filetypes=[("binarne", "*.bin"), ("CSV", "*.csv")],
        )
        if not path:
            return
        if path.endswith(".csv"):
            with open(path, "w", encoding="utf-8") as f:
                f.write("sample,code\n")
                for i, c in enumerate(self.last_payload):
                    f.write(f"{i},{c}\n")
        else:
            with open(path, "wb") as f:
                f.write(self.last_payload)
        self.log(f"zapisano {len(self.last_payload)} bajtów: {path}")

    def auto_tick(self):
        if self.auto_var.get() and self.dev.sock is not None:
            self.on_status()
        self.after(1000, self.auto_tick)

    # -------------------------------------------------------- wyniki

    def poll_results(self):
        try:
            while True:
                name, ok, value = self.results.get_nowait()
                try:
                    self.handle_result(name, ok, value)
                except Exception as exc:
                    # błąd obsługi jednego wyniku nie może zatrzymać pętli GUI
                    self.log(f"[{name}] wyjątek w GUI: {exc}")
        except queue.Empty:
            pass
        self.after(100, self.poll_results)

    def handle_result(self, name, ok, value):
        if not ok:
            self.log(f"[{name}] BŁĄD: {value}")
            if name in RECORD_TASKS:
                self.log("jeśli ramka się rozjechała, rozłącz i połącz ponownie")
            if name == "config_apply":
                self.log("konfiguracja aktywna nie została zmieniona")
            return

        if name == "connect":
            self.set_connected(True)
            self.log(value)
            self.on_status()
            self.on_config_read()
        elif name == "disconnect":
            self.set_connected(False)
            self.state_var.set("-")
            self.rid_var.set("-")
            self.log(value)
        elif name == "cmd":
            self.log(f"OK: {value}")
            self.on_status()
        elif name == "status":
            st, rid = value
            self.state_var.set(f"{STATE_NAMES.get(st, '?')} (0x{st:02X})")
            self.rid_var.set(str(rid))
        elif name in ("config_read", "config_apply", "config_reset"):
            if name == "config_apply":
                self.applied_cfg = self.pending_cfg
            self._show_config(value)
            labels = {
                "config_read": "wczytano konfigurację z płytki",
                "config_apply": "konfiguracja zatwierdzona (COMMIT)",
                "config_reset": "wartości domyślne ustawione w konfiguracji oczekującej",
            }
            self.log(labels[name])
            self.on_status()
        elif name == "cycle_level":
            info, payload, ptrs, ptr_err = value
            self.show_record(info, payload, check=True)
            self.check_pointers(info, ptrs, ptr_err)
            self.on_status()
        elif name in RECORD_TASKS:
            info, payload = value
            self.show_record(info, payload, check=False)
            self.on_status()

    def show_record(self, info, payload, check=False):
        self.last_info = info
        self.last_payload = payload

        self.ax.clear()
        self.ax.set_xlabel("próbka")
        self.ax.set_ylabel("napięcie [V] (przybliżone)")
        self.ax.grid(True, alpha=0.3)

        if payload:
            try:
                vref = float(self.vref_var.get())
            except ValueError:
                vref = 4.1
            volts = [c * vref / 256.0 for c in payload]
            self.ax.plot(volts, linewidth=0.8)

            # pozycja wyzwolenia: indeks próbki w rekordzie
            nch = 2 if info["mask"] == 0x03 else 1
            trig_x = info["trigger_pos"] * nch
            if 0 <= trig_x < len(payload):
                self.ax.axvline(
                    trig_x,
                    color="red",
                    linestyle="--",
                    linewidth=1,
                    label=f"wyzwolenie (próbka {info['trigger_pos']})",
                )
                self.ax.legend(loc="upper right")

            self.ax.set_title(
                f"rekord {info['rid']}, {info['samples']} próbek/kanał, mask 0x{info['mask']:02X}"
            )
            self.log(
                f"rekord {info['rid']}: {len(payload)} bajtów, "
                f"kod min {min(payload)} max {max(payload)}, "
                f"TRIGGER_POS {info['trigger_pos']}"
            )
            if check:
                self.check_trigger(info, payload)
        else:
            self.ax.set_title(f"rekord {info['rid']}: brak próbek (mask 0x00)")
            self.log(f"rekord {info['rid']}: brak próbek")

        self.canvas.draw_idle()

    def check_trigger(self, info, payload):
        """Sprawdza pozycję wyzwolenia względem poziomu i krawędzi zatwierdzonej konfiguracji."""
        cfg = self.applied_cfg
        if cfg is None:
            self.log("kontrola wyzwolenia: brak zatwierdzonej konfiguracji w tej sesji")
            return
        if info["mask"] != 0x01 or len(payload) < 2:
            return

        level = cfg["level"]
        edge = cfg["edge"]
        pre = info["trigger_pos"]
        if pre >= len(payload) - 1:
            self.log(f"kontrola wyzwolenia: TRIGGER_POS {pre} poza rekordem")
            return

        if pre == 0:
            # próbka 0 jest próbką wyzwalającą: musi leżeć po stronie poziomu zgodnej z krawędzią
            s0, s1 = payload[0], payload[1]
            rising_ok = s0 >= level
            falling_ok = s0 <= level
            if edge == 0x00:
                ok = rising_ok
            elif edge == 0x01:
                ok = falling_ok
            else:
                ok = rising_ok or falling_ok
            self.log(
                f"kontrola wyzwolenia: TRIGGER_POS=0, próbki 0 i 1: {s0} {s1}, "
                f"poziom {level}, {'zgodne' if ok else 'NIEZGODNE'} z krawędzią {edge}"
            )
            return

        rising = [
            i for i in range(1, len(payload)) if payload[i - 1] < level <= payload[i]
        ]
        falling = [
            i for i in range(1, len(payload)) if payload[i - 1] > level >= payload[i]
        ]
        if edge == 0x00:
            candidates = rising
        elif edge == 0x01:
            candidates = falling
        else:
            candidates = sorted(rising + falling)

        if not candidates:
            self.log(
                f"kontrola wyzwolenia: brak przejścia przez poziom {level} w rekordzie"
            )
            return

        nearest = min(candidates, key=lambda i: abs(i - pre))
        self.log(
            f"kontrola wyzwolenia: TRIGGER_POS={pre}, najbliższe przejście w próbce {nearest} "
            f"(różnica {nearest - pre}), próbki wokół pozycji: "
            f"{payload[pre - 1]} {payload[pre]} {payload[pre + 1]}, poziom {level}"
        )

    def check_pointers(self, info, ptrs, ptr_err):
        """Sprawdza (trigger - write) mod N == pre dla rekordu z cyklu z poziomem."""
        cfg = self.applied_cfg
        if cfg is None:
            self.log("wskazniki: brak zatwierdzonej konfiguracji w tej sesji")
            return
        if ptrs is None:
            self.log(f"wskazniki: nie odczytano ({ptr_err})")
            return
        n = cfg["record_length"]
        pre = cfg["pre"]
        write_ptr = ptrs["write"]
        trigger_ptr = ptrs["trigger"]
        if write_ptr >= n or trigger_ptr >= n:
            self.log(
                f"wskazniki: poza buforem N={n}: write {write_ptr}, trigger {trigger_ptr}"
            )
            return
        diff = (trigger_ptr - write_ptr) % n
        ok = diff == pre
        self.log(
            f"wskazniki: {'OK' if ok else 'NIEZGODNE'}: write {write_ptr}, "
            f"trigger {trigger_ptr}, (trigger - write) mod {n} = {diff}, "
            f"oczekiwane pre {pre}, TRIGGER_POS z nagłówka {info['trigger_pos']}"
        )

    def on_close(self):
        self.dev.close()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
