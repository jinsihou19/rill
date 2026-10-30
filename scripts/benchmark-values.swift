// swiftc -O Sources/RillCore/RESP.swift Sources/RillCore/RESPStreamDecoder.swift scripts/benchmark-values.swift -o build/benchmark-values
import Foundation
@main struct Bench {
 static func measure(_ name: String, _ frame: Data) throws {
  let start=ContinuousClock.now; var buffer=Data(); var value: RESPValue?
  for offset in stride(from:0,to:frame.count,by:1024) { buffer.append(frame.subdata(in:offset..<min(offset+1024,frame.count))); value=try RESPCodec.decode(buffer)?.value }
  precondition(value != nil)
  let c=start.duration(to:.now).components
  print(String(format:"%@ %d bytes / 1KiB fragments: %.2f ms",name,frame.count,Double(c.seconds)*1000+Double(c.attoseconds)/1e15))
 }
 static func stream(_ name: String, _ frame: Data) throws {
  let start=ContinuousClock.now; var decoder=RESPStreamDecoder(); var value: RESPValue?
  for offset in stride(from:0,to:frame.count,by:1024) { try decoder.append(frame.subdata(in:offset..<min(offset+1024,frame.count))); if let result=try decoder.next() { value=result } }
  precondition(value != nil)
  let c=start.duration(to:.now).components
  print(String(format:"stream %@ %d bytes / 1KiB fragments: %.2f ms",name,frame.count,Double(c.seconds)*1000+Double(c.attoseconds)/1e15))
 }
 static func main() throws {
  let bulk=RESPCodec.encode([Data(repeating:65,count:1024*1024)])
  let array=RESPCodec.encode((0..<10000).map { _ in Data(repeating:65,count:80) })
  try measure("bulk",bulk); try measure("array",array); try stream("bulk",bulk); try stream("array",array)
  let start=ContinuousClock.now; let hex=DataPresentation.hex(Data(repeating:65,count:1024*1024)); precondition(!hex.isEmpty)
  let c=start.duration(to:.now).components
  print(String(format:"hex 1MiB: %.2f ms",Double(c.seconds)*1000+Double(c.attoseconds)/1e15))
 }
}
