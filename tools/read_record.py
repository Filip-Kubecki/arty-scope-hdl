import socket
import struct
import time

HOST = "192.168.1.50"
PORT = 5000
HDR_LEN = 64


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError(f"zamkniete po {len(buf)} z {n} bajtow")
        buf.extend(chunk)
    return bytes(buf)


def request(sock, cmd, addr, data=0):
    frame = bytes([0xC7, 0xE2, cmd, addr]) + struct.pack(">I", data)
    sock.sendall(frame)
    resp = recv_exact(sock, 8)
    if resp[0:2] != b"\xc7\xe2":
        raise RuntimeError(f"zly magic w odpowiedzi: {resp.hex(' ')}")
    return resp


def show(label, resp):
    print(f"{label:<22}{resp.hex(' ')}")


def check_no_extra(sock):
    sock.settimeout(0.5)
    try:
        extra = sock.recv(1024)
    except socket.timeout:
        extra = b""
    sock.settimeout(5)
    if extra:
        print(
            f"UWAGA: po bloku zostalo {len(extra)} nadmiarowych bajtow: {extra[:16].hex(' ')}"
        )
    else:
        print("po bloku nie ma nadmiarowych bajtow")


def main():
    sock = socket.create_connection((HOST, PORT), timeout=5)

    # 0. sprowadz do IDLE; stan z poprzedniej sesji zostaje w FPGA
    show("STOP:", request(sock, 0x01, 0x12))
    show("stan (IDLE):", request(sock, 0x02, 0xA0))

    # 1. READ przed rekordem: oczekiwany ERROR_NOT_READY
    r = request(sock, 0x01, 0x17)
    show("READ (oczekiwany 06):", r)
    if r[2] != 0xFF or r[7] != 0x06:
        print("UWAGA: READ przed rekordem nie dal ERROR_NOT_READY, koniec")
        sock.close()
        return

    # 2. ARM, FORCE_TRIGGER, czekamy na zapis rekordu
    show("ARM:", request(sock, 0x01, 0x11))
    show("FORCE_TRIGGER:", request(sock, 0x01, 0x13))
    time.sleep(1.0)
    show("stan (READY):", request(sock, 0x02, 0xA0))
    show("RECORD_ID:", request(sock, 0x02, 0xA4))

    # 3. READ_RECORD: 8 bajtow odpowiedzi, potem blok
    r = request(sock, 0x01, 0x17)
    show("READ_RECORD:", r)
    if r[2] != 0x81:
        print("brak rekordu, koniec")
        sock.close()
        return

    hdr = recv_exact(sock, HDR_LEN)
    magic_ok = hdr[0:2] == b"\xc7\xe2"
    typ = hdr[2]
    plen = struct.unpack(">I", hdr[4:8])[0]
    rid = struct.unpack(">I", hdr[8:12])[0]
    mask = hdr[12]
    sbits = hdr[13]
    smp = struct.unpack(">I", hdr[16:20])[0]
    nch = 2 if mask == 0x03 else 1
    expected = smp * nch * sbits // 8

    print()
    print("naglowek:")
    print("  magic:       ", "OK" if magic_ok else "ZLE", hdr[0:2].hex(" "))
    print("  typ:         ", hex(typ))
    print("  PAYLOAD_LEN: ", plen)
    print("  RECORD_ID:   ", rid)
    print("  mask:        ", hex(mask))
    print("  SAMPLE_BITS: ", sbits)
    print("  SAMPLES/CH:  ", smp)
    print(
        "  spojnosc:    ", "OK" if plen == expected else f"ZLE (oczekiwano {expected})"
    )

    payload = recv_exact(sock, plen)
    with open("build/record.bin", "wb") as f:
        f.write(payload)

    values = list(payload)
    print()
    print("probki:")
    print("  odebrano:    ", len(payload), "bajtow")
    print("  min / max:   ", min(values), "/", max(values))
    print("  unikalnych:  ", len(set(values)))
    print("  pierwsze 32: ", payload[:32].hex(" "))
    print("  zapisano:     build/record.bin")
    print()
    check_no_extra(sock)

    sock.close()


if __name__ == "__main__":
    main()
