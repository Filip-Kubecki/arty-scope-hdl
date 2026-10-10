import socket
import time

HOST = "192.168.1.50"
PORT = 5000
TOTAL = 1_000_000_000  # 1 GB
CHUNK = 65536

PATTERN = bytes(range(256)) * ((CHUNK + 256) // 256 + 2)

sock = socket.create_connection((HOST, PORT), timeout=5)

received = 0
bad_blocks = 0
first_err = None
first_byte = None

t0 = time.perf_counter()

while received < TOTAL:
    chunk = sock.recv(CHUNK)
    if not chunk:
        print(f"polaczenie zamkniete po {received} bajtach")
        break

    if first_byte is None:
        first_byte = chunk[0]

    start = received & 0xFF
    expected = PATTERN[start : start + len(chunk)]

    if chunk != expected:
        bad_blocks += 1
        if first_err is None:
            for i, (got, exp) in enumerate(zip(chunk, expected)):
                if got != exp:
                    first_err = (received + i, exp, got)
                    break

    received += len(chunk)

elapsed = time.perf_counter() - t0

print(f"pierwszy bajt:    {first_byte:02X}")
print(f"odebrano:         {received} bajtow")
print(f"bloki z bledem:   {bad_blocks}")
if first_err:
    pos, exp, got = first_err
    print(f"pierwszy blad:    pozycja {pos}, oczekiwano {exp:02X}, odebrano {got:02X}")
else:
    print("pierwszy blad:    brak")
print(f"czas:             {elapsed:.1f} s")
print(f"przepustowosc:    {received / elapsed / 1e6:.2f} MB/s")

sock.close()
