// Dsp.swift - receive: I/Q -> upper-sideband audio; transmit: one-tone
// frequency tracking. Straight ports of UsbDemod and ToneTracker in qmx_tci.py.

import Foundation
import Accelerate

let tciSampleRate = 48000
let dialOffsetHz = 12000.0          // the QMX's dial is +12 kHz in its I/Q stream

/// 48 kHz complex I/Q -> 48 kHz USB audio (0.1-3.2 kHz above the dial).
/// Shift dial+1650 Hz to 0, low-pass +-1550 Hz (complex), shift back up by
/// 1650 Hz and keep the real part. A slow AGC keeps the level steady.
final class UsbDemod {
    let fs: Double
    let center = 1650.0
    private var h: [Double]
    private var tailRe: [Double]
    private var tailIm: [Double]
    private var ph1 = 0.0, ph2 = 0.0
    private let w1: Double, w2: Double
    private var gain = 1.0
    private(set) var levelDb = -120.0

    init(fs: Int = tciSampleRate, taps: Int = 255) {
        self.fs = Double(fs)
        let cut = 1550.0
        var hh = [Double](repeating: 0, count: taps)
        let m = Double(taps - 1)
        for i in 0..<taps {
            let n = Double(i) - m / 2
            let x = 2 * cut / self.fs * n
            let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let black = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / m) + 0.08 * cos(4 * Double.pi * Double(i) / m)
            hh[i] = sinc * (2 * cut / self.fs) * black
        }
        let sum = hh.reduce(0, +)
        h = hh.map { $0 / sum }
        tailRe = [Double](repeating: 0, count: taps - 1)
        tailIm = [Double](repeating: 0, count: taps - 1)
        w1 = -2 * Double.pi * (dialOffsetHz + center) / self.fs
        w2 = 2 * Double.pi * center / self.fs
    }

    /// Interleaved little-endian int16 I,Q -> mono float audio.
    func process(_ s16: Data) -> [Float] {
        let n = s16.count / 4
        if n == 0 { return [] }
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        s16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for k in 0..<n {
                let i = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * k, as: Int16.self))
                let q = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * k + 2, as: Int16.self))
                let a = Double(i) / 32768.0, b = Double(q) / 32768.0
                let p = ph1 + w1 * Double(k)
                let c = cos(p), s = sin(p)
                re[k] = a * c - b * s
                im[k] = a * s + b * c
            }
        }
        ph1 = (ph1 + w1 * Double(n)).truncatingRemainder(dividingBy: 2 * Double.pi)
        let xr = tailRe + re, xi = tailIm + im
        let taps = h.count
        var yr = [Double](repeating: 0, count: n)
        var yi = [Double](repeating: 0, count: n)
        // h is symmetric, so correlation (vDSP_convD) == convolution
        vDSP_convD(xr, 1, h, 1, &yr, 1, vDSP_Length(n), vDSP_Length(taps))
        vDSP_convD(xi, 1, h, 1, &yi, 1, vDSP_Length(n), vDSP_Length(taps))
        tailRe = Array(xr[(xr.count - (taps - 1))...])
        tailIm = Array(xi[(xi.count - (taps - 1))...])
        var audio = [Double](repeating: 0, count: n)
        var sq = 0.0
        for k in 0..<n {
            let p = ph2 + w2 * Double(k)
            let v = (yr[k] * cos(p) - yi[k] * sin(p)) * 2.0
            audio[k] = v
            sq += v * v
        }
        ph2 = (ph2 + w2 * Double(n)).truncatingRemainder(dividingBy: 2 * Double.pi)
        let rms = (sq / Double(n)).squareRoot() + 1e-12
        levelDb = 20 * log10(rms)
        // slow AGC towards an RMS of 0.05 (about -26 dBFS); gain limited to +60 dB
        let target = 0.05 / rms
        gain += (min(target, 1000.0) - gain) * 0.02
        return audio.map { Float(max(-1.0, min(1.0, $0 * gain))) }
    }
}

/// Measures the frequency of a one-tone signal (FT8/FT4/JS8/WSPR/tune) from its
/// rising zero crossings and reports a new tone each time the frequency settles
/// somewhere new (within plateauHz for plateauMs). Silence is reported as 0.
final class ToneTracker {
    static let plateauHz = 0.25
    static let plateauMs = 8.0
    static let changeHz = 0.5
    static let silence = 0.01

    let fs: Double
    private var n = 0.0                 // samples seen
    private var prev = 0.0
    private var lastCross: Double?
    private var periods: [(t: Double, f: Double)] = []
    private(set) var tone = 0.0
    private var quiet = 0

    init(fs: Int = tciSampleRate) { self.fs = Double(fs) }

    func reset() {
        n = 0; prev = 0; lastCross = nil; periods.removeAll(); tone = 0; quiet = 0
    }

    /// Mono samples in; (sample index, tone Hz) changes out.
    func feed(_ x: [Double]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        if x.isEmpty { return out }
        let base = n
        var lastLoud = -1
        for (i, v) in x.enumerated() {
            if abs(v) > Self.silence { lastLoud = i }
            let a = i == 0 ? prev : x[i - 1]
            // rising crossing between sample i-1 and i
            if a <= 0 && v > 0 {
                let t = base + Double(i) - 1 + (v != a ? -a / (v - a) : 0)
                if let lc = lastCross {
                    let p = t - lc
                    if p > 0 { periods.append((t, fs / p)) }
                }
                lastCross = t
            }
        }
        if lastLoud >= 0 { quiet = x.count - 1 - lastLoud } else { quiet += x.count }
        prev = x[x.count - 1]
        n += Double(x.count)
        if Double(quiet) > fs * 0.004 {                 // 4 ms of silence
            periods.removeAll()
            lastCross = nil
            if tone != 0 {
                tone = 0
                out.append((n - Double(quiet), 0))
            }
            return out
        }
        let span = fs * Self.plateauMs / 1000.0
        while let first = periods.first, first.t < n - 8 * span { periods.removeFirst() }   // keep ~64 ms
        let recent = periods.filter { $0.t >= n - span }.map(\.f)
        if recent.count >= 4, let first = periods.first, first.t <= n - span,
           let lo = recent.min(), let hi = recent.max(), hi - lo <= 2 * Self.plateauHz {
            let f = recent.reduce(0, +) / Double(recent.count)
            if abs(f - tone) >= Self.changeHz && f >= 50 && f <= 4000 {
                // Report the change where the frequency crossed half way from the old
                // tone to the new one - the symbol boundary. After silence: where it began.
                var at = first.t
                if tone != 0 {
                    let mid = (tone + f) / 2
                    let oldSide = tone > mid
                    for p in periods.reversed() where (p.f > mid) == oldSide {
                        at = p.t
                        break
                    }
                }
                tone = f
                out.append((at, f))
            }
        }
        return out
    }
}
