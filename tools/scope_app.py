#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scope_app.py - GUI do płytki przez protokół TCP (port 5000).

Funkcje:
  - połączenie z płytką i rozłączenie
  - odczyt stanu akwizycji i numeru rekordu (opcjonalnie auto co 1 s)
  - ręczne STOP, ARM, FORCE_TRIGGER
  - odczyt rekordu z wykresem (kod 8-bit przeliczony na V przez Vref)
  - pełny cykl: ARM -> FORCE -> czekaj na READY -> odczyt rekordu
  - zapis rekordu do .bin albo .csv

Wymagania: python3, tkinter, matplotlib.
  sudo apt install python3-tk     (jeśli brak tkinter)

Uruchomienie z katalogu repo:
    python3 tools/scope_gui.py
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

ADDR_STATE = 0xA0
ADDR_RECORD_ID = 0xA4
ADDR_ARM = 0x11
ADDR_STOP = 0x12
ADDR_FORCE = 0x13
ADDR_READ_RECORD = 0x17

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


class ProtocolError(Exception):
    pass


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
            if resp[2] == RSP_ERROR:
                raise ProtocolError(ERROR_NAMES.get(resp[7], f"kod {resp[7]:#04x}"))
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


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("arty-scope: sterowanie")
        self.geometry("1100x800")

        self.dev = Device()
        self.tasks = queue.Queue()
        self.results = queue.Queue()
        self.worker = Worker(self.tasks, self.results)
        self.worker.start()

        self.last_info = None
        self.last_payload = None

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

        ctl = ttk.LabelFrame(self, text="Sterowanie", padding=8)
        ctl.pack(fill="x", padx=8, pady=4)

        self.control_buttons = [
            ttk.Button(
                ctl, text="STOP", command=lambda: self.on_cmd(ADDR_STOP, "STOP")
            ),
            ttk.Button(ctl, text="ARM", command=lambda: self.on_cmd(ADDR_ARM, "ARM")),
            ttk.Button(
                ctl,
                text="FORCE_TRIGGER",
                command=lambda: self.on_cmd(ADDR_FORCE, "FORCE_TRIGGER"),
            ),
            ttk.Button(ctl, text="Odczytaj rekord", command=self.on_read),
            ttk.Button(
                ctl,
                text="Pełny cykl: ARM -> FORCE -> READY -> odczyt",
                command=self.on_cycle,
            ),
        ]
        for b in self.control_buttons:
            b.pack(side="left", padx=4)

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
        st = self.dev.request(CMD_READ, ADDR_STATE)[7]
        rid = struct.unpack(">I", self.dev.request(CMD_READ, ADDR_RECORD_ID)[4:8])[0]
        return st, rid

    def t_command(self, addr, label):
        resp = self.dev.request(CMD_WRITE, addr)
        if resp[2] == RSP_ERROR:
            raise ProtocolError(f"{label}: {ERROR_NAMES.get(resp[7], resp[7])}")
        return label

    def t_read(self):
        return self.dev.read_record()

    def t_cycle(self):
        self.t_command(ADDR_ARM, "ARM")
        self.t_command(ADDR_FORCE, "FORCE_TRIGGER")
        deadline = time.time() + 5.0
        while time.time() < deadline:
            st, _ = self.t_status()
            if st == ST_READY:
                return self.dev.read_record()
            time.sleep(0.1)
        raise ProtocolError("timeout: brak READY po 5 s")

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

    def on_cycle(self):
        self.submit("cycle", self.t_cycle)

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
                self.handle_result(name, ok, value)
        except queue.Empty:
            pass
        self.after(100, self.poll_results)

    def handle_result(self, name, ok, value):
        if not ok:
            self.log(f"[{name}] BŁĄD: {value}")
            if name in ("read", "cycle"):
                self.log("jeśli ramka się rozjechała, rozłącz i połącz ponownie")
            return

        if name == "connect":
            self.set_connected(True)
            self.log(value)
            self.on_status()
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
        elif name in ("read", "cycle"):
            info, payload = value
            self.show_record(info, payload)
            self.on_status()

    def show_record(self, info, payload):
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
            self.ax.set_title(
                f"rekord {info['rid']}, {info['samples']} próbek/kanał, mask 0x{info['mask']:02X}"
            )
            self.log(
                f"rekord {info['rid']}: {len(payload)} bajtów, "
                f"kod min {min(payload)} max {max(payload)}"
            )
        else:
            self.ax.set_title(f"rekord {info['rid']}: brak próbek (mask 0x00)")
            self.log(f"rekord {info['rid']}: brak próbek")

        self.canvas.draw_idle()

    def on_close(self):
        self.dev.close()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
