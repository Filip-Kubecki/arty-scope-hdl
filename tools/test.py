#!/usr/bin/env python3

import argparse
import os
import socket
import sys
import threading
import time

LINE_RATE_MBPS = 100.0  # łącze Fast Ethernet


def connect(args):
    source = (args.src, 0) if args.src else None
    sock = socket.create_connection(
        (args.host, args.port), timeout=args.timeout, source_address=source
    )
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    return sock


def echo(sock, data):
    """Wysyła dane w osobnym wątku i jednocześnie odbiera echo (bez ryzyka zakleszczenia)."""
    errors = []

    def sender():
        try:
            sock.sendall(data)
        except OSError as exc:
            errors.append(exc)

    thread = threading.Thread(target=sender, daemon=True)
    thread.start()

    received = bytearray()
    try:
        while len(received) < len(data):
            chunk = sock.recv(65536)
            if not chunk:
                break
            received += chunk
    except socket.timeout:
        errors.append("timeout przy odbiorze")

    thread.join(timeout=1)
    return bytes(received), errors


def compare(sent, got):
    if got == sent:
        return True
    print(f"BŁĄD: wysłano {len(sent)} B, odebrano {len(got)} B")
    limit = min(len(sent), len(got))
    first = next((i for i in range(limit) if sent[i] != got[i]), None)
    if first is not None:
        print(
            f"  pierwsza różnica na pozycji {first}: "
            f"wysłano 0x{sent[first]:02X}, odebrano 0x{got[first]:02X}"
        )
    elif len(got) < len(sent):
        print(
            f"  odebrane dane kończą się wcześniej, brakuje bajtów od pozycji {len(got)}"
        )
    else:
        print(f"  odebrano więcej danych niż wysłano (nadmiar od pozycji {len(sent)})")
    return False


def run_echo(args, data, name):
    sock = connect(args)
    t0 = time.perf_counter()
    got, errors = echo(sock, data)
    elapsed = time.perf_counter() - t0
    sock.close()

    for err in errors:
        print(f"Uwaga: {err}")

    if compare(data, got):
        rate = len(data) / elapsed / 1e6
        print(
            f"{name}: OK, {len(data)} B w {elapsed:.3f} s ({rate:.2f} MB/s w obie strony)"
        )
        return 0
    print(f"{name}: BŁĄD")
    return 1


def cmd_echo_all(args):
    data = bytes(range(256)) + bytes(range(255, -1, -1))
    return run_echo(args, data, "echo-all")


def cmd_echo_big(args):
    data = os.urandom(args.size)
    return run_echo(args, data, f"echo-big ({args.size} B)")


def cmd_stream(args):
    sock = connect(args)
    pattern = bytes(range(256))
    expected = pattern * 8192  # 2 MiB wzorca do porównań
    buf = bytearray(1 << 20)
    view = memoryview(buf)

    total = 0
    pos = None  # oczekiwana wartość pierwszego bajtu kolejnego kawałka
    bad_chunks = 0
    first_bad = None
    t0 = None
    last_t = None
    last_total = 0

    print("Odbieram strumień... (Ctrl+C przerywa)")
    try:
        while True:
            now = time.perf_counter()
            if t0 is not None and now - t0 >= args.seconds:
                break
            try:
                n = sock.recv_into(buf)
            except socket.timeout:
                print(
                    "Brak danych (timeout). Czy FPGA jest w trybie strumienia "
                    "(BTN1, LED3 świeci ciągle)?"
                )
                sock.close()
                return 1
            if n == 0:
                print("Połączenie zamknięte przez FPGA.")
                break

            if t0 is None:  # pomiar liczony od pierwszych danych
                t0 = last_t = time.perf_counter()
                pos = buf[0]

            if view[:n] != expected[pos : pos + n]:
                bad_chunks += 1
                if first_bad is None:
                    idx = next(i for i in range(n) if buf[i] != (pos + i) & 0xFF)
                    first_bad = total + idx
                pos = (buf[n - 1] + 1) & 0xFF  # synchronizacja po błędzie
            else:
                pos = (pos + n) & 0xFF
            total += n

            now = time.perf_counter()
            if now - last_t >= 1.0:
                interval_rate = (total - last_total) / (now - last_t) / 1e6
                print(f"  {now - t0:5.1f} s: {interval_rate:6.2f} MB/s")
                last_t, last_total = now, total
    except KeyboardInterrupt:
        print("Przerwano.")

    sock.close()

    if t0 is None or total == 0:
        print("Nie odebrano żadnych danych.")
        return 1

    elapsed = time.perf_counter() - t0
    rate = total / elapsed / 1e6
    print()
    print(f"Odebrano {total} B w {elapsed:.2f} s")
    print(
        f"Przepustowość: {rate:.2f} MB/s ({rate * 8:.1f} Mbit/s, "
        f"{rate * 8 / LINE_RATE_MBPS * 100:.0f}% prędkości łącza)"
    )
    if bad_chunks == 0:
        print(
            "Ciągłość danych: OK (brak utraconych, powtórzonych ani przestawionych bajtów)"
        )
        return 0
    print(
        f"Ciągłość danych: BŁĄD ({bad_chunks} kawałków z niezgodnością, "
        f"pierwsza na pozycji {first_bad})"
    )
    return 1


def main():
    parser = argparse.ArgumentParser(description="Testy TCP z FPGA")
    parser.add_argument("--host", default="192.168.1.50", help="adres IP FPGA")
    parser.add_argument("--port", type=int, default=5000, help="port TCP")
    parser.add_argument(
        "--src",
        default="192.168.1.10",
        help="adres źródłowy karty sieciowej połączonej z Arty (pusty = domyślny)",
    )
    parser.add_argument(
        "--timeout", type=float, default=10.0, help="limit czasu operacji w sekundach"
    )

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("echo-all", help="echo wszystkich wartości bajtu").set_defaults(
        func=cmd_echo_all
    )

    big = sub.add_parser("echo-big", help="echo dużej ilości losowych danych")
    big.add_argument(
        "--size", type=int, default=65536, help="liczba bajtów (domyślnie 65536)"
    )
    big.set_defaults(func=cmd_echo_big)

    stream = sub.add_parser("stream", help="pomiar przepustowości FPGA -> komputer")
    stream.add_argument("--seconds", type=float, default=10.0, help="czas pomiaru")
    stream.set_defaults(func=cmd_stream)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
