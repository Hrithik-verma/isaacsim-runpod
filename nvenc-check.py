#!/usr/bin/env python3
"""Does this GPU let us OPEN an NVENC session? Exit 0 = yes, 1 = no.

Isaac's streaming path is useless without NVENC, but it fails late and
opaquely: signaling connects, the session starts, then the server closes the
data channel and the client reports only "the streamer data channel is
closing" -- which sends you debugging the network instead of the encoder.

Checking the library loads is NOT enough. On rented GeForce hosts (seen twice
on Vast.ai, RTX 3060, driver 580.173.02) CUDA initialises, the library loads,
NvEncodeAPIGetMaxSupportedVersion reports 13.0 -- and then
nvEncOpenEncodeSessionEx returns 2 (NV_ENC_ERR_NO_ENCODE_DEVICE). Only
actually opening a session tells you the truth.
"""
import ctypes
import sys


def main() -> int:
    try:
        cuda = ctypes.CDLL("libcuda.so.1")
    except OSError as exc:
        print(f"[nvenc-check] no CUDA driver library: {exc}")
        return 1

    if cuda.cuInit(0) != 0:
        print("[nvenc-check] cuInit failed -- no usable GPU in this container")
        return 1

    try:
        ctypes.CDLL("libnvidia-encode.so.1")
    except OSError as exc:
        print(f"[nvenc-check] libnvidia-encode missing: {exc}")
        print("[nvenc-check] the container was started without the driver's "
              "video capability (NVIDIA_DRIVER_CAPABILITIES must include video/all)")
        return 1

    try:
        import PyNvVideoCodec as nvc
    except ImportError:
        print("[nvenc-check] PyNvVideoCodec not installed; cannot verify that a "
              "session can actually be opened. Skipping (not a failure).")
        return 0

    try:
        nvc.CreateEncoder(640, 480, "NV12", False)
    except Exception as exc:  # noqa: BLE001 - any failure means no NVENC
        detail = str(exc).replace("\n", " ")[:200]
        print(f"[nvenc-check] FAILED to open an NVENC session: {detail}")
        return 1

    print("[nvenc-check] OK: NVENC session opened -- this host can stream.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
