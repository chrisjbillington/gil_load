import sys
import numpy as np
import threading
import gil_load


x = np.random.randn(4096, 4096)
y = np.random.randn(4096, 4096)

def inplace_fft(a):
    for i in range(10):
        a[:] = np.fft.fft2(a).real


gil_load.init()
gil_load.start(output=sys.stdout, output_interval=1)

thread1 = threading.Thread(target=inplace_fft, args=(x,))
thread2 = threading.Thread(target=inplace_fft, args=(y,))

thread1.start()
thread2.start()

thread1.join()
thread2.join()

gil_load.stop()

print(gil_load.get(N=4))
