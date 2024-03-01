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
        private lazy var audioUnit: AVAudioEngine = {
            let engine = AVAudioEngine()
            engine.mainMixerNode.volume = 1.0
            try! engine.start()
            return engine
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

                    let playerNode = AVAudioPlayerNode()
                    audioUnit.attach(playerNode)

                    let audioUnitData = AudioUnitData(audioUnit: audioUnit, playerNode: playerNode, buffer: audioBuffer!)
                    audioUnits[soundId] = audioUnitData

                    result(soundId)
                } catch {
                    result(-1)
                }
            case "play":
                let soundId = call.arguments as! Int

                guard let audioUnitData = audioUnits[soundId] else {
                    result(-1)
                    break
                }

                if !audioUnitData.playerNode.isPlaying {
                    audioUnitData.playerNode.play()
                }

                result(nil)
            case "pause":
                let soundId = call.arguments as! Int

                guard let audioUnitData = audioUnits[soundId] else {
                    result(-1)
                    break
                }

                if audioUnitData.playerNode.isPlaying {
                    audioUnitData.playerNode.pause()
                }

                result(nil)
            case "resume":
                let soundId = call.arguments as! Int

                guard let audioUnitData = audioUnits[soundId] else {
                    result(-1)
                    break
                }

                if !audioUnitData.playerNode.isPlaying {
                    audioUnitData.playerNode.play()
                }

                result(nil)
            case "stop":
                let soundId = call.arguments as! Int

                guard let audioUnitData = audioUnits[soundId] else {
                    result(-1)
                    break
                }

                if audioUnitData.playerNode.isPlaying {
                    audioUnitData.playerNode.stop()
                }

                result(nil)
            case "setVolume":
                let soundId = call.arguments as! Int
                let volumeLeft = call.arguments as! Double
                let volumeRight = call.arguments as! Double

                guard let audioUnitData = audioUnits[soundId] else {
                    result(-1)
                    break
                }

                // Normalize volumeLeft and volumeRight to ensure they sum up to 1.0
                let totalVolume = volumeLeft + volumeRight
                let normalizedVolumeLeft = volumeLeft / totalVolume
                let normalizedVolumeRight = volumeRight / totalVolume

                // Set panning
                audioUnitData.playerNode.pan = Float(normalizedVolumeRight - normalizedVolumeLeft)

                result(nil)
            case "setRate":
                let streamId = attributes["streamId"] as! Int
                let rate = attributes["rate"] as! Double
                let success = setRate(streamId: streamId, rate: rate)
                result(success)
            case "release":
                // Release resources
                result(nil)
            default:
                result("notImplemented")
            }
        }

        private func setRate(streamId: Int, rate: Double) -> Bool {
            guard let audioUnitData = audioUnits[streamId] else {
                return false
            }
            audioUnitData.playerNode.rate = Float(rate)
            return true
        }

        func stopAllStreams() {
            for (streamId, audioUnit) in audioUnits {
                audioUnit.stop()
                // Remove the stopped audio unit from the dictionary
                audioUnits[streamId] = nil
            }
        }

        private func playerByStreamId(streamId: Int) -> NowPlaying? {
            let audioPlayer = nowPlaying[streamId]
            return audioPlayer
        }

        private func playerBySoundId(soundId: Int) -> AVAudioPlayerNode? {
            return audioUnits[soundId]?.playerNode
        }

        private struct NowPlaying {
            let player: AVAudioPlayerNode
            //let delegate: SoundpoolDelegate
        }
    }

    private var audioUnits = [Int: AudioUnitData]()

    private struct AudioUnitData {
        let audioUnit: AVAudioEngine
        let playerNode: AVAudioPlayerNode
        let buffer: AVAudioPCMBuffer
    }
}
