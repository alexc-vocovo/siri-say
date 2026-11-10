// siri-say: a `say`-like command-line tool built on AVSpeechSynthesizer,
// so it can use the Siri (neural) voices that `say` / NSSpeechSynthesizer can't.

import AVFoundation
import Foundation

// MARK: - Helpers

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("siri-say: \(msg)\n".utf8))
    exit(code)
}

func usage() -> Never {
    print("""
    Usage: siri-say [-v voice] [-r rate] [-o outfile] [-f file | message ...]

      -v, --voice VOICE     Voice name or identifier (substring match). '-v ?' lists voices.
      -r, --rate WPM        Speaking rate in words per minute (like `say`, ~175 is normal).
          --raw-rate N      AVSpeechUtterance rate 0.0–1.0 (0.5 is normal); overrides -r.
          --pitch N         Pitch multiplier 0.5–2.0 (default 1.0).
          --volume N        Volume 0.0–1.0 (default 1.0).
      -o, --output-file F   Write audio to F instead of speaking (.aiff .wav .caf .m4a).
      -f, --input-file F    Read text from F ('-' for stdin).
          --siri            Only consider Siri voices (with -v, or for listing with -v ?).
      -l, --list            List voices (same as -v ?).
      -h, --help            Show this help.

    With no message and no -f, text is read from stdin.
    Default voice: the best Siri voice for your locale, else the system default.
    """)
    exit(0)
}

func isSiri(_ v: AVSpeechSynthesisVoice) -> Bool {
    v.identifier.lowercased().contains(".siri.")
}

func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
    if isSiri(v) { return "siri" }
    switch v.quality {
    case .premium: return "premium"
    case .enhanced: return "enhanced"
    default: return "default"
    }
}

func rank(_ v: AVSpeechSynthesisVoice) -> Int {
    (isSiri(v) ? 100 : 0) + v.quality.rawValue
}

// MARK: - Argument parsing

var voiceQuery: String?
var wpm: Double?
var rawRate: Float?
var pitch: Float = 1.0
var volume: Float = 1.0
var outputPath: String?
var inputPath: String?
var siriOnly = false
var listOnly = false
var words: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
func next(_ flag: String) -> String {
    guard !args.isEmpty else { fail("option \(flag) requires an argument") }
    return args.removeFirst()
}

while !args.isEmpty {
    let a = args.removeFirst()
    // Support say-style "-vSamantha" / "-r200" attached values.
    if a.count > 2, a.hasPrefix("-"), !a.hasPrefix("--"),
       let flag = a.dropFirst().first, "vrof".contains(flag) {
        args.insert(String(a.dropFirst(2)), at: 0)
        args.insert("-\(flag)", at: 0)
        continue
    }
    switch a {
    case "-h", "--help": usage()
    case "-v", "--voice": voiceQuery = next(a)
    case "-r", "--rate":
        guard let n = Double(next(a)), n > 0 else { fail("invalid rate") }
        wpm = n
    case "--raw-rate":
        guard let n = Float(next(a)) else { fail("invalid raw rate") }
        rawRate = n
    case "--pitch":
        guard let n = Float(next(a)) else { fail("invalid pitch") }
        pitch = n
    case "--volume":
        guard let n = Float(next(a)) else { fail("invalid volume") }
        volume = n
    case "-o", "--output-file": outputPath = next(a)
    case "-f", "--input-file": inputPath = next(a)
    case "--siri": siriOnly = true
    case "-l", "--list": listOnly = true
    case "--": words.append(contentsOf: args); args.removeAll()
    default:
        if a.hasPrefix("-") && a != "-" { fail("unknown option \(a) (try --help)") }
        words.append(a)
    }
}

// MARK: - Voices

// The public `speechVoices()` hides Siri voices from most processes. AVFoundation has a
// private `+_speechVoicesIncludingSiri` that returns them; fall back to the public list
// if a future OS removes it.
func loadVoices() -> [AVSpeechSynthesisVoice] {
    let sel = NSSelectorFromString("_speechVoicesIncludingSiri")
    let cls: AnyObject = AVSpeechSynthesisVoice.self
    if cls.responds(to: sel),
       let list = cls.perform(sel)?.takeUnretainedValue() as? [AVSpeechSynthesisVoice],
       !list.isEmpty {
        return list
    }
    return AVSpeechSynthesisVoice.speechVoices()
}

let allVoices = loadVoices()
let candidates = siriOnly ? allVoices.filter(isSiri) : allVoices

if listOnly || voiceQuery == "?" {
    let sorted = candidates.sorted {
        ($0.language, -rank($0), $0.name) < ($1.language, -rank($1), $1.name)
    }
    for v in sorted {
        let name = v.name.padding(toLength: 24, withPad: " ", startingAt: 0)
        let lang = v.language.padding(toLength: 8, withPad: " ", startingAt: 0)
        let q = qualityLabel(v).padding(toLength: 9, withPad: " ", startingAt: 0)
        print("\(name) \(lang) \(q) \(v.identifier)")
    }
    if candidates.filter(isSiri).isEmpty {
        FileHandle.standardError.write(Data("""
        siri-say: no Siri voices found. Download one in System Settings → Accessibility →
        Spoken Content → System Voice → Manage Voices… (they're listed as "Siri Voice N").\n
        """.utf8))
    }
    exit(0)
}

func pickVoice() -> AVSpeechSynthesisVoice? {
    if let q = voiceQuery?.lowercased() {
        // Exact identifier, then exact name, then substring on name or identifier.
        if let v = candidates.first(where: { $0.identifier.lowercased() == q }) { return v }
        let exact = candidates.filter { $0.name.lowercased() == q }
        if let v = exact.max(by: { rank($0) < rank($1) }) { return v }
        let partial = candidates.filter {
            $0.name.lowercased().contains(q) || $0.identifier.lowercased().contains(q)
        }
        if let v = partial.max(by: { rank($0) < rank($1) }) { return v }
        fail("voice '\(voiceQuery!)' not found (use -v ? to list)")
    }
    // Default: best Siri voice matching the current locale, then language, then any Siri voice.
    let locale = Locale.current
    let full = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    let lang = (locale.language.languageCode?.identifier ?? "en").lowercased()
    let siri = allVoices.filter(isSiri)
    if let v = siri.first(where: { $0.language.lowercased() == full }) { return v }
    if let v = siri.first(where: { $0.language.lowercased().hasPrefix(lang) }) { return v }
    if siriOnly { return siri.first }
    return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
}

// MARK: - Text

var text: String
if let path = inputPath {
    if path == "-" {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        do { text = try String(contentsOfFile: path, encoding: .utf8) }
        catch { fail("can't read \(path): \(error.localizedDescription)") }
    }
} else if !words.isEmpty {
    text = words.joined(separator: " ")
} else {
    text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}
text = text.trimmingCharacters(in: .whitespacesAndNewlines)
if text.isEmpty { exit(0) }

// MARK: - Utterance

let utterance = AVSpeechUtterance(string: text)
utterance.voice = pickVoice()
if let r = rawRate {
    utterance.rate = r
} else if let w = wpm {
    // `say` default is ~175 wpm; AVSpeechUtteranceDefaultSpeechRate (0.5) is roughly that.
    // The AV scale isn't linear, so this is an approximation.
    let r = AVSpeechUtteranceDefaultSpeechRate * Float(w / 175.0)
    utterance.rate = min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
}
utterance.pitchMultiplier = pitch
utterance.volume = volume

let synth = AVSpeechSynthesizer()

// MARK: - Output to file

if let out = outputPath {
    let url = URL(fileURLWithPath: out)
    let ext = url.pathExtension.lowercased()
    var file: AVAudioFile?
    var gotAudio = false

    synth.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {  // end of stream
            if !gotAudio { fail("synthesis produced no audio") }
            file = nil  // closes the file
            exit(0)
        }
        gotAudio = true
        do {
            if file == nil {
                var settings = pcm.format.settings
                switch ext {
                case "m4a", "aac", "mp4":
                    settings = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: pcm.format.sampleRate,
                        AVNumberOfChannelsKey: pcm.format.channelCount,
                    ]
                case "aiff", "aif", "aifc", "wav", "caf", "":
                    break
                default:
                    fail("unsupported output extension .\(ext) (use .aiff .wav .caf .m4a)")
                }
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
            }
            try file!.write(from: pcm)
        } catch {
            fail("can't write \(out): \(error.localizedDescription)")
        }
    }
    dispatchMain()
}

// MARK: - Speak

final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { exit(0) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { exit(1) }
}

let delegate = Delegate()
synth.delegate = delegate
signal(SIGINT) { _ in exit(130) }
synth.speak(utterance)
dispatchMain()
