import Flutter
import UIKit
import AVFoundation

public class SwiftSoundpoolPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "pl.ukaszapps/soundpool", binaryMessenger: registrar.messenger())
        let instance = SwiftSoundpoolPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private let counter = Atomic<Int>(0)
    private lazy var wrappers = Dictionary<Int, SwiftSoundpoolPlugin.SoundpoolWrapper>()

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initSoundpool":
            let attributes = call.arguments as! NSDictionary
            let maxStreams = attributes["maxStreams"] as! Int
            let enableRate = (attributes["ios_enableRate"] as? Bool) ?? true
            let wrapper = SoundpoolWrapper(maxStreams, enableRate)
            let index = counter.increment()
            wrappers[index] = wrapper
            result(index)
        case "dispose":
            let attributes = call.arguments as! NSDictionary
            let index = attributes["poolId"] as! Int

            guard let wrapper = wrapperById(id: index) else {
                print("Dispose attempt on not available pool (id: \(index)).")
                result(FlutterError(code: "invalidArgs", message: "Invalid poolId", details: "Pool with id \(index) not found"))
                break
            }
            wrapper.stopAllStreams()
            wrappers.removeValue(forKey: index)
            result(nil)
        default:
            let attributes = call.arguments as! NSDictionary
            let index = attributes["poolId"] as! Int

            guard let wrapper = wrapperById(id: index) else {
                print("Action '\(call.method)' attempt on not available pool (id: \(index)).")
                result(FlutterError(code: "invalidArgs", message: "Invalid poolId", details: "Pool with id \(index) not found"))
                break
            }
            wrapper.handle(call, result: result)
        }
    }

    private func wrapperById(id: Int) -> SwiftSoundpoolPlugin.SoundpoolWrapper? {
        if (id < 0){
            return nil
        }
        let wrapper = wrappers[id]
        return wrapper
    }

    class SoundpoolWrapper : NSObject {
        private var maxStreams: Int
        private var enableRate: Bool
        private lazy var streamsCount: Dictionary<Int, Int> = [Int: Int]()
        private lazy var nowPlaying: Dictionary<Int, NowPlaying> = [Int: NowPlaying]()
        private lazy var audioUnit: AudioUnit = {
            var unit: AudioUnit?
            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_RemoteIO,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            let comp = AudioComponentFindNext(nil, &desc)
            AudioComponentInstanceNew(comp!, &unit)
            return unit!
        }()

        init(_ maxStreams: Int, _ enableRate: Bool){
            self.maxStreams = maxStreams
            self.enableRate = enableRate
        }

        public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
            let attributes = call.arguments as! NSDictionary
            switch call.method {
            case "load":
                let soundId = call.arguments as! Int
                let soundUri = call.arguments as! String

                guard let url = URL(string: soundUri) else {
                    result(-1)
                    break
                }

                do {
                    let asset = AVURLAsset(url: url)
                    let audioFile = try AVAudioFile(forReading: asset.url)

                    var audioFormat = audioFile.processingFormat
                    let audioFrames = UInt32(audioFile.length)
                    let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: audioFrames)

                    try audioFile.read(into: audioBuffer!)

                    let audioUnitData = AudioUnitData(audioUnit: audioUnit, buffer: audioBuffer!)
                    nowPlaying[soundId] = NowPlaying(audioUnitData: audioUnitData)

                    result(soundId)
                } catch {
                    result(-1)
                }
            case "play":
                let soundId = call.arguments as! Int

                guard let nowPlayingData = nowPlaying[soundId] else {
                    result(-1)
                    break
                }

                let audioUnit = nowPlayingData.audioUnitData.audioUnit
                AudioOutputUnitStart(audioUnit)
                result(nil)
            case "pause":
                let soundId = call.arguments as! Int

                guard let nowPlayingData = nowPlaying[soundId] else {
                    result(-1)
                    break
                }

                let audioUnit = nowPlayingData.audioUnitData.audioUnit
                AudioOutputUnitStop(audioUnit)
                result(nil)
            case "resume":
                let soundId = call.arguments as! Int

                guard let nowPlayingData = nowPlaying[soundId] else {
                    result(-1)
                    break
                }

                let audioUnit = nowPlayingData.audioUnitData.audioUnit
                AudioOutputUnitStart(audioUnit)
                result(nil)
            case "stop":
                let soundId = call.arguments as! Int

                guard let nowPlayingData = nowPlaying[soundId] else {
                    result(-1)
                    break
                }

                let audioUnit = nowPlayingData.audioUnitData.audioUnit
                AudioOutputUnitStop(audioUnit)
                result(nil)
            case "setVolume":
                let soundId = call.arguments as! Int
                let volumeLeft = call.arguments as! Double
                let volumeRight = call.arguments as! Double

                guard let nowPlayingData = nowPlaying[soundId] else {
                    result(-1)
                    break
                }

                let audioUnit = nowPlayingData.audioUnitData.audioUnit
                AudioUnitSetParameter(audioUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, Float(volumeLeft), 0)
                AudioUnitSetParameter(audioUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, 1, Float(volumeRight), 0)
                result(nil)
            case "setRate":
                let soundId = call.arguments as! Int
                let rate = call.arguments as! Double

                guard let nowPlayingData = nowPlaying[soundId] else {
                    result(-1)
                    break
                }

                let audioUnit = nowPlayingData.audioUnitData.audioUnit
                AudioUnitSetProperty(audioUnit, kAudioUnitProperty_PlaybackRate, kAudioUnitScope_Global, 0, &rate, UInt32(MemoryLayout.size(ofValue: rate)))
                result(nil)
            case "release":
                for (_, wrapper) in wrappers {
                    wrapper.stopAllStreams()
                }
                wrappers.removeAll()
                result(nil)
            default:
                result("notImplemented")
            }
        }

        func stopAllStreams() {
            for (_, nowPlayingData) in nowPlaying {
                let audioUnit = nowPlayingData.audioUnitData.audioUnit
                AudioOutputUnitStop(audioUnit)
            }
            nowPlaying.removeAll()
        }
    }

    private struct AudioUnitData {
        let audioUnit: AudioUnit
        let buffer: AVAudioPCMBuffer

        init(audioUnit: AudioUnit, buffer: AVAudioPCMBuffer) {
            self.audioUnit = audioUnit
            self.buffer = buffer
        }
    }

    private struct NowPlaying {
        let audioUnitData: AudioUnitData
    }
}
