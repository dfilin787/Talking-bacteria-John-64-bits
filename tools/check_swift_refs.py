#!/usr/bin/env python3

import os
import re
import sys

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "TalkingJohn", "Sources")

STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
LINE_COMMENT = re.compile(r"//[^\n]*")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)

def strip_noise(text):
    text = BLOCK_COMMENT.sub("", text)
    text = STRING.sub('""', text)
    text = LINE_COMMENT.sub("", text)
    return text

def main():
    texts = {}
    for name in sorted(os.listdir(SRC)):
        if name.endswith(".swift"):
            with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                texts[name] = fh.read()
    if not texts:
        print("Swift-файлы не найдены")
        return 1

    joined = "\n".join(texts.values())
    problems = []

    selectors = set(re.findall(r"#selector\((\w+)", joined))
    functions = set(re.findall(r"func (\w+)", joined))
    for selector in sorted(selectors - functions):
        problems.append("#selector(%s) — метод не найден" % selector)

    properties = set(re.findall(r"\b(?:let|var)\s+(\w+)", joined))
    referenced = set(re.findall(r"self\.(\w+)", joined))
    for name in sorted(referenced - properties - functions):
        problems.append("self.%s — поле или метод не объявлены" % name)

    types = set(re.findall(r"\b(?:class|struct|enum|protocol)\s+(\w+)", joined))
    instantiated = set(re.findall(r"\b([A-Z]\w+)\(", joined))
    known_system = {
        "CGRect", "CGPoint", "CGSize", "UIColor", "UIImage", "UIView", "UILabel",
        "UIImageView", "UIButton", "UITapGestureRecognizer", "UIPanGestureRecognizer",
        "UIWindow", "UIApplication",
        "UISceneConfiguration", "UIGraphicsImageRenderer", "CADisplayLink", "CAFrameRateRange",
        "AVAudioEngine", "AVAudioPlayerNode", "AVAudioFormat", "AVAudioPCMBuffer",
        "AVAudioFrameCount", "AVAudioConverter", "AVAudioFile", "AVAudioSession",
        "AVAudioApplication", "DispatchQueue", "Timer", "Date", "Bundle", "FileManager",
        "NSLock", "NSNumber", "NSData", "Int", "Double", "Float", "UInt", "UInt32",
        "String", "Array", "Set", "Bool", "TimeInterval", "CFTimeInterval",
        "SoundTouchProcessor", "NSError", "NSObject", "NSString",
        "CACurrentMediaTime", "CGAffineTransform", "CGFloat", "NSLog",
        "UnsafeBufferPointer", "UnsafeMutableBufferPointer", "UnsafeRawBufferPointer",
        "CharacterSet", "URL", "URLSession", "NotificationCenter", "UserDefaults",
        "IndexSet", "DateFormatter", "NSAttributedString", "NSMutableAttributedString",
        "UILongPressGestureRecognizer", "ObjectIdentifier", "UUID",
        "AVAssetWriter", "AVAssetWriterInput", "AVAssetWriterInputPixelBufferAdaptor",
        "AVAudioTime", "AVAudioFramePosition", "AVVideoCodecType",
        "CMTime", "CMTimeCompare", "CMTimeSubtract", "CMTimeMake",
        "CMItemCount", "CMTimeScale", "CMSampleBuffer", "CMSampleBufferCreate",
        "CMSampleTimingInfo", "CMBlockBuffer", "CMBlockBufferCreateWithMemoryBlock",
        "CMBlockBufferReplaceDataBytes", "CMAudioFormatDescription",
        "CMAudioFormatDescriptionCreate",
        "CVPixelBuffer", "CVPixelBufferPool", "CVPixelBufferGetBaseAddress",
        "CVPixelBufferGetBytesPerRow", "CVPixelBufferGetHeight", "CVPixelBufferGetWidth",
        "CVPixelBufferLockBaseAddress", "CVPixelBufferUnlockBaseAddress",
        "CVPixelBufferPoolCreatePixelBuffer", "CGContext", "CGColorSpaceCreateDeviceRGB",
        "PHPhotoLibrary", "PHAssetChangeRequest", "PHAsset",
    }
    for name in sorted(instantiated - types - known_system):
        problems.append("тип %s используется, но не объявлен в проекте" % name)

    for name, text in texts.items():
        clean = strip_noise(text)
        for opener, closer in (("{", "}"), ("(", ")"), ("[", "]")):
            if clean.count(opener) != clean.count(closer):
                problems.append("%s: %s%s не сбалансированы (%d/%d)" % (
                    name, opener, closer, clean.count(opener), clean.count(closer)))

    print("Swift-файлов: %d, типов: %d, методов: %d, селекторов: %d"
          % (len(texts), len(types), len(functions), len(selectors)))
    if problems:
        print("\nПРОБЛЕМЫ:")
        for problem in problems:
            print("  ✗", problem)
        return 1
    print("Ссылки и баланс скобок в порядке.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
