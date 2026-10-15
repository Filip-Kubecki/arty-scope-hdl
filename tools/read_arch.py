import matplotlib.pyplot as plt

data = open("build/record.bin", "rb").read()
plt.plot(list(data))
plt.xlabel("próbka")
plt.ylabel("kod 8-bit")
plt.title("record.bin")
plt.show()
