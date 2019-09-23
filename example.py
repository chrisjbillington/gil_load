import sys
import numpy as np
import threading
import gil_load

N_THREADS = 4

NPTS = 4096
gil_load.init()

def do_some_work():
    for i in range(5):
        x = np.random.randn(NPTS, NPTS)
        x[:] = np.fft.fft2(x).real

gil_load.start(av_sample_interval=0.005, output=sys.stdout, output_interval=1)

threads = []
for i in range(N_THREADS):
    thread = threading.Thread(target=do_some_work, daemon=True)
    threads.append(thread)
    thread.start()


for thread in threads:
    thread.join()

gil_load.stop()

stats = gil_load.get()
print(gil_load.format(stats))
