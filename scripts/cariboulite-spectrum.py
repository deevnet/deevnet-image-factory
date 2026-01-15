#!/usr/bin/env python3
"""
CaribouLite SDR Spectrum Analyzer Test

Captures RF samples from CaribouLite SDR and generates a spectrum plot.
This validates that the SDR hardware is functioning correctly by:
  1. Opening the SoapySDR device
  2. Configuring the receiver
  3. Capturing IQ samples
  4. Computing FFT spectrum
  5. Generating a spectrum plot image

Usage:
    ./cariboulite-spectrum.py [options]

Options:
    -f, --freq      Center frequency in MHz (default: 100.0)
    -b, --bandwidth Sample rate/bandwidth in MHz (default: 2.0)
    -g, --gain      Receiver gain in dB (default: 50)
    -n, --samples   Number of samples to capture (default: 262144)
    -o, --output    Output image path (default: /tmp/cariboulite_spectrum.png)
    -c, --channel   Channel: 0=S1G, 1=HiF (default: 1)
    -q, --quiet     Suppress text output, only return exit code
    -h, --help      Show this help message

Exit codes:
    0 - Success, spectrum captured and image generated
    1 - SoapySDR/device error
    2 - Capture error (no data or all zeros)
    3 - Missing dependencies
"""

import sys
import argparse


def check_dependencies():
    """Check that required Python packages are available."""
    missing = []

    try:
        import numpy
    except ImportError:
        missing.append("python3-numpy")

    try:
        import matplotlib
    except ImportError:
        missing.append("python3-matplotlib")

    try:
        import SoapySDR
    except ImportError:
        missing.append("python3-soapysdr")

    return missing


def main():
    parser = argparse.ArgumentParser(
        description="CaribouLite SDR Spectrum Analyzer Test",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage:")[0]
    )
    parser.add_argument("-f", "--freq", type=float, default=100.0,
                        help="Center frequency in MHz (default: 100.0)")
    parser.add_argument("-b", "--bandwidth", type=float, default=2.0,
                        help="Sample rate in MHz (default: 2.0)")
    parser.add_argument("-g", "--gain", type=float, default=50.0,
                        help="Receiver gain in dB (default: 50)")
    parser.add_argument("-n", "--samples", type=int, default=262144,
                        help="Number of samples (default: 262144)")
    parser.add_argument("-o", "--output", type=str,
                        default="/tmp/cariboulite_spectrum.png",
                        help="Output image path")
    parser.add_argument("-c", "--channel", type=int, default=1,
                        choices=[0, 1],
                        help="Channel: 0=S1G, 1=HiF (default: 1)")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="Suppress output, only return exit code")

    args = parser.parse_args()

    def log(msg):
        if not args.quiet:
            print(msg)

    # Check dependencies first
    missing = check_dependencies()
    if missing:
        log(f"[ERROR] Missing dependencies: {', '.join(missing)}")
        log("Install with: sudo apt install " + " ".join(missing))
        return 3

    # Now import the dependencies
    import numpy as np
    import matplotlib
    matplotlib.use('Agg')  # Non-interactive backend
    import matplotlib.pyplot as plt
    import SoapySDR
    from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_CF32

    # Convert units
    center_freq = args.freq * 1e6
    sample_rate = args.bandwidth * 1e6
    num_samples = args.samples
    channel_name = "S1G" if args.channel == 0 else "HiF"

    log(f"[INFO] CaribouLite Spectrum Analyzer")
    log(f"[INFO] Channel: {channel_name} (ch {args.channel})")
    log(f"[INFO] Center frequency: {args.freq} MHz")
    log(f"[INFO] Sample rate: {args.bandwidth} MHz")
    log(f"[INFO] Gain: {args.gain} dB")
    log(f"[INFO] Samples: {num_samples}")

    # Find and open CaribouLite device
    log("[INFO] Opening CaribouLite device...")

    try:
        results = SoapySDR.Device.enumerate("driver=Cariboulite")
        if not results:
            log("[ERROR] No CaribouLite device found")
            return 1

        sdr = SoapySDR.Device(dict(driver="Cariboulite", channel=channel_name))
    except Exception as e:
        log(f"[ERROR] Failed to open device: {e}")
        return 1

    try:
        # Configure the receiver
        log("[INFO] Configuring receiver...")
        sdr.setSampleRate(SOAPY_SDR_RX, args.channel, sample_rate)
        sdr.setFrequency(SOAPY_SDR_RX, args.channel, center_freq)
        sdr.setGain(SOAPY_SDR_RX, args.channel, args.gain)

        # Setup stream
        rx_stream = sdr.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CF32, [args.channel])
        sdr.activateStream(rx_stream)

        # Capture samples
        log("[INFO] Capturing samples...")
        samples = np.zeros(num_samples, dtype=np.complex64)
        total_read = 0

        while total_read < num_samples:
            chunk_size = min(4096, num_samples - total_read)
            chunk = np.zeros(chunk_size, dtype=np.complex64)
            sr = sdr.readStream(rx_stream, [chunk], chunk_size, timeoutUs=1000000)

            if sr.ret > 0:
                samples[total_read:total_read + sr.ret] = chunk[:sr.ret]
                total_read += sr.ret
            elif sr.ret == SoapySDR.SOAPY_SDR_TIMEOUT:
                log("[WARN] Stream timeout, retrying...")
                continue
            else:
                log(f"[ERROR] Stream error: {sr.ret}")
                break

        # Deactivate and close stream
        sdr.deactivateStream(rx_stream)
        sdr.closeStream(rx_stream)

    except Exception as e:
        log(f"[ERROR] Capture failed: {e}")
        return 2
    finally:
        sdr = None  # Release device

    if total_read < num_samples // 2:
        log(f"[ERROR] Insufficient samples captured: {total_read}/{num_samples}")
        return 2

    log(f"[INFO] Captured {total_read} samples")

    # Check for all-zeros (hardware issue)
    if np.all(samples == 0):
        log("[ERROR] Captured data is all zeros (hardware issue)")
        return 2

    # Compute spectrum using FFT
    log("[INFO] Computing spectrum...")

    # Use Welch's method for better spectrum estimate
    fft_size = 4096
    num_ffts = total_read // fft_size

    if num_ffts < 1:
        fft_size = total_read
        num_ffts = 1

    # Apply window and compute averaged spectrum
    window = np.hanning(fft_size)
    spectrum = np.zeros(fft_size)

    for i in range(num_ffts):
        segment = samples[i * fft_size:(i + 1) * fft_size]
        windowed = segment * window
        fft_result = np.fft.fftshift(np.fft.fft(windowed))
        spectrum += np.abs(fft_result) ** 2

    spectrum /= num_ffts
    spectrum_db = 10 * np.log10(spectrum + 1e-10)

    # Create frequency axis
    freq_axis = np.fft.fftshift(np.fft.fftfreq(fft_size, 1/sample_rate))
    freq_axis_mhz = (freq_axis + center_freq) / 1e6

    # Compute statistics
    peak_power = np.max(spectrum_db)
    noise_floor = np.median(spectrum_db)
    dynamic_range = peak_power - noise_floor

    log(f"[INFO] Peak power: {peak_power:.1f} dB")
    log(f"[INFO] Noise floor: {noise_floor:.1f} dB")
    log(f"[INFO] Dynamic range: {dynamic_range:.1f} dB")

    # Generate plot
    log(f"[INFO] Generating spectrum plot: {args.output}")

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8))
    fig.suptitle(f"CaribouLite SDR Spectrum - {channel_name} Channel", fontsize=14)

    # Spectrum plot
    ax1.plot(freq_axis_mhz, spectrum_db, linewidth=0.5, color='blue')
    ax1.fill_between(freq_axis_mhz, spectrum_db, noise_floor - 10,
                     alpha=0.3, color='blue')
    ax1.set_xlabel("Frequency (MHz)")
    ax1.set_ylabel("Power (dB)")
    ax1.set_title(f"RF Spectrum @ {args.freq} MHz (BW: {args.bandwidth} MHz, Gain: {args.gain} dB)")
    ax1.grid(True, alpha=0.3)
    ax1.set_xlim(freq_axis_mhz[0], freq_axis_mhz[-1])

    # Add statistics annotation
    stats_text = f"Peak: {peak_power:.1f} dB\nNoise floor: {noise_floor:.1f} dB\nDynamic range: {dynamic_range:.1f} dB"
    ax1.annotate(stats_text, xy=(0.02, 0.98), xycoords='axes fraction',
                 verticalalignment='top', fontsize=9,
                 bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.8))

    # Waterfall-style time-frequency plot (spectrogram)
    # Use a subset of samples for spectrogram
    spectrogram_samples = min(total_read, 65536)
    nperseg = 256

    from scipy import signal
    f, t, Sxx = signal.spectrogram(samples[:spectrogram_samples],
                                    fs=sample_rate,
                                    nperseg=nperseg,
                                    noverlap=nperseg//2,
                                    return_onesided=False)

    # Shift frequencies to center
    f = np.fft.fftshift(f)
    Sxx = np.fft.fftshift(Sxx, axes=0)
    f_mhz = (f + center_freq) / 1e6
    t_ms = t * 1000

    im = ax2.pcolormesh(t_ms, f_mhz, 10 * np.log10(Sxx + 1e-10),
                        shading='gouraud', cmap='viridis')
    ax2.set_xlabel("Time (ms)")
    ax2.set_ylabel("Frequency (MHz)")
    ax2.set_title("Spectrogram (Time-Frequency)")
    fig.colorbar(im, ax=ax2, label='Power (dB)')

    plt.tight_layout()
    plt.savefig(args.output, dpi=150, bbox_inches='tight')
    plt.close()

    log(f"[PASS] Spectrum image saved to: {args.output}")
    log("[PASS] SDR hardware validation successful")

    return 0


if __name__ == "__main__":
    sys.exit(main())
