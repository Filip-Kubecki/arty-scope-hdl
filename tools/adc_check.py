#!/usr/bin/env python3
"""Diagnostyka ADC: pobiera rekord i sprawdza, czy próbki są zmienne (szum)
czy stałe, bez podłączania sygnału.

Użycie:
    python3 adc_check.py --host 192.168.1.50 --port 5000

Wymaga tylko standardowej biblioteki Pythona. Zapisuje surowy rekord do pliku.
"""

import argparse
import collections
import socket
import statistics
import struct
import sys

MAGIC = bytes([0xC7, 0xE2])
CMD_WRITE = 0x01
CMD_READ = 0x02

ADDR_STOP = 0x12
ADDR_ARM = 0x11
ADDR_FORCE = 0x13
ADDR_READ_RECORD = 0x17
ADDR_STATE = 0xA0
ADDR_WPTR = 0xA1
ADDR_TPTR = 0xA2

STATES = {0: "IDLE", 1: "ARMED", 2: "CAPTURE", 3: "READY"}
ERRORS = {
    1: "UNKNOWN_COMMAND",
    2: "BAD_ADDRESS",
    3: "READ_ONLY",
    4: "WRITE_ONLY",
    5: "BAD_VALUE",
    6: "NOT_READY",
}


class Link:
    def __init__(self, host, port, timeout):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)

    def close(self):
        self.sock.close()

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("połączenie zamknięte")
            buf += chunk
        return buf

    def request(self, cmd, addr, data=0):
        frame = MAGIC + bytes([cmd, addr]) + struct.pack(">I", data)
        self.sock.sendall(frame)
        return self._recv_exact(8)

    def read(self, addr):
        resp = self.request(CMD_READ, addr)
        check_error(resp, f"READ 0x{addr:02X}")
        return int.from_bytes(resp[4:8], "big")

    def write(self, addr, data=0):
        resp = self.request(CMD_WRITE, addr, data)
        check_error(resp, f"WRITE 0x{addr:02X}")
        return resp


def check_error(resp, label):
    if resp[0:2] != MAGIC:
        raise RuntimeError(f"{label}: zła ramka odpowiedzi {resp.hex(' ')}")
    if resp[2] == 0xFF:
        code = resp[7]
        raise RuntimeError(f"{label}: ERROR {ERRORS.get(code, code)} (0x{code:02X})")


def wait_state(link, wanted, timeout_s):
    import time

    end = time.time() + timeout_s
    state = None
    while time.time() < end:
        state = link.read(ADDR_STATE) & 0xFF
        if state in wanted:
            return state
        time.sleep(0.1)
    return state


def read_block(link, idle_s):
    """Zbiera wszystkie bajty, które przychodzą po odpowiedzi, aż do ciszy."""
    link.sock.settimeout(idle_s)
    data = bytearray()
    try:
        while True:
            chunk = link.sock.recv(65536)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    return bytes(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.1.50")
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument(
        "--header",
        type=int,
        default=64,
        help="długość nagłówka bloku w bajtach (RECORD_HEADER_LENGTH)",
    )
    ap.add_argument("--out", default="rekord.bin")
    args = ap.parse_args()

    link = Link(args.host, args.port, args.timeout)
    try:
        print("Start: STOP -> ARM")
        link.write(ADDR_STOP)
        link.write(ADDR_ARM)
        state = wait_state(link, {3}, 1.0)
        print(
            f"Stan po ARM: {STATES.get(state, state)}, "
            f"wptr={link.read(ADDR_WPTR)}, tptr={link.read(ADDR_TPTR)}"
        )

        if state != 3:
            print("Wymuszam wyzwolenie (FORCE)")
            link.write(ADDR_FORCE)
            state = wait_state(link, {3}, 3.0)
            print(
                f"Stan po FORCE: {STATES.get(state, state)}, "
                f"wptr={link.read(ADDR_WPTR)}, tptr={link.read(ADDR_TPTR)}"
            )

        if state != 3:
            print("Akwizycja nie doszła do READY. Przerywam.")
            sys.exit(1)

        print("READ_RECORD")
        resp = link.request(CMD_WRITE, ADDR_READ_RECORD, 0)
        check_error(resp, "READ_RECORD")
        raw = read_block(link, 1.0)
        print(f"Odebrano bajtów po odpowiedzi: {len(raw)}")
        with open(args.out, "wb") as f:
            f.write(raw)
        print(f"Surowy rekord zapisany do: {args.out}")
        print("Pierwsze 32 bajty:", raw[:32].hex(" "))

        payload = raw[args.header :]
        if not payload:
            print("Brak danych po nagłówku. ADC nic nie wysłał.")
            sys.exit(2)

        counts = collections.Counter(payload)
        unique = len(counts)
        mean = statistics.fmean(payload)
        sd = statistics.pstdev(payload)
        print()
        print(f"Próbek (bajtów po nagłówku): {len(payload)}")
        print(f"Różnych wartości: {unique}")
        print(
            f"min={min(payload)} max={max(payload)} "
            f"średnia={mean:.2f} odchylenie={sd:.2f}"
        )
        print("Najczęstsze wartości:")
        for value, n in counts.most_common(8):
            print(f"  0x{value:02X}: {n} ({100 * n / len(payload):.1f}%)")
        print()
        if unique <= 1:
            print("WYNIK: dane STAŁE (brak szumu). ADC albo szyna nie działa.")
        elif sd < 1.0:
            print(
                "WYNIK: dane prawie stałe (szum poniżej 1 kodu). Sprawdź zasilanie i masę."
            )
        else:
            print("WYNIK: dane ZMIENNE (jest szum). Tor danych działa.")
    finally:
        link.close()


if __name__ == "__main__":
    main()
