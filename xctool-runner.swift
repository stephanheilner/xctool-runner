#!/usr/bin/env swift

import Foundation

// Don't buffer println
setbuf(__stdoutp, nil)

var arguments = Process.arguments.filter { !$0.hasPrefix("-") }
let launchPath = arguments.removeAtIndex(0)

func printMessage(message: String) {
    let labeledMessage = "xctool-runner: " + message
    println(String(count: countElements(labeledMessage), repeatedValue: UnicodeScalar("=")))
    println(labeledMessage)
    println(String(count: countElements(labeledMessage), repeatedValue: UnicodeScalar("=")))
}

let maxNumberOfAttemptsWithoutProgress = 5

extension NSTask {
    func setStartsNewProcessGroup(flag: Bool) {
        // Private API on NSConcreteTask
    }
}

func exec(launchPath: String, arguments: String...) -> Int {
    let task = NSTask()
    task.setStartsNewProcessGroup(false)
    task.launchPath = launchPath
    task.arguments = Array(arguments)
    task.launch()
    task.waitUntilExit()
    return Int(task.terminationStatus)
}

extension Array {
    func contains<T where T : Equatable>(obj: T) -> Bool {
        return self.filter({ $0 as? T == obj }).count > 0
    }
    
    mutating func remove<U: Equatable>(element: U) {
        let anotherSelf = self
        removeAll(keepCapacity: true)
        for (i, current) in enumerate(anotherSelf) {
            if current as U != element {
                self.append(current)
            }
        }
    }
    
    func partition(n: Int) -> [Array] {
        var result: [Array] = []
        
        let division = Double(count) / Double(n)
        for i in 0..<n {
            let start = Int(round(division * Double(i)))
            let end = Int(round(division * Double(i + 1)))
            let partition = Array(self[start..<end])
            result.append(partition)
        }
        
        return result
    }
}

struct Test: Equatable {
    let className: String
    let methodName: String
}

func ==(lhs: Test, rhs: Test) -> Bool {
    return (lhs.className == rhs.className) &&
        (lhs.methodName == rhs.methodName)
}

let scriptDirectoryPath = NSFileManager.defaultManager().currentDirectoryPath.stringByAppendingPathComponent(launchPath).stringByDeletingLastPathComponent
let xctoolPath = scriptDirectoryPath.stringByAppendingPathComponent("Vendor/xctool/xctool.sh")
let buildPath = NSFileManager.defaultManager().currentDirectoryPath.stringByAppendingPathComponent("build")

let workspace = NSUserDefaults.standardUserDefaults().stringForKey("workspace") ?? ""
if workspace.isEmpty {
    printMessage("Missing -workspace argument")
    exit(1)
}

let scheme = NSUserDefaults.standardUserDefaults().stringForKey("scheme") ?? ""
if scheme.isEmpty {
    printMessage("Missing -scheme argument")
    exit(1)
}

if arguments.isEmpty {
    printMessage("Unexpected number of arguments")
    exit(1)
}

while !arguments.isEmpty {
    let mode = arguments.removeAtIndex(0)
    switch mode {
    case "build":
        printMessage("Building workspace=\(workspace), scheme=\(scheme)")
        
        func build() -> Bool {
            return exec(xctoolPath, "-workspace", workspace, "-scheme", scheme, "-sdk", "iphonesimulator", "CONFIGURATION_BUILD_DIR=\(buildPath)", "clean", "build-tests", "-reporter", "pretty") == 0
        }
        
        if !build() {
            printMessage("Failed to build")
            exit(1)
        }
    case "test":
        let numberOfPartitions = max(1, NSUserDefaults.standardUserDefaults().stringForKey("partition-count")?.toInt() ?? 1)
        let partitionIndex = max(0, min(numberOfPartitions, NSUserDefaults.standardUserDefaults().stringForKey("partition")?.toInt() ?? 0))
        
        var deviceSpecs: [(name: String, version: String)] = []
        if let deviceSpecsString = NSUserDefaults.standardUserDefaults().stringForKey("devices") ?? "" {
            for deviceSpecString in deviceSpecsString.componentsSeparatedByString(";") {
                let deviceSpecParts = deviceSpecString.componentsSeparatedByString(",")
                let deviceSpec = (name: deviceSpecParts[0], version: deviceSpecParts[1])
                deviceSpecs.append(deviceSpec)
            }
        } else {
            deviceSpecs = [
                (name: "iPhone 5", version: "8.1"),
                (name: "iPad 2", version: "8.1"),
            ]
        }
        
        if arguments.isEmpty {
            printMessage("Unexpected number of arguments")
            exit(1)
        }
        
        let target = arguments.removeAtIndex(0)
        
        printMessage("Testing workspace=\(workspace), scheme=\(scheme), target=\(target), partition=\(partitionIndex), partition-count=\(numberOfPartitions)")
        
        func devices() -> [(destination: String, description: String, name: String, version: String)] {
            return deviceSpecs.map { deviceSpec in
                return (
                    destination: "platform=iOS Simulator,OS=\(deviceSpec.version),name=\(deviceSpec.name)",
                    description: "\(deviceSpec.name) / iOS \(deviceSpec.version)",
                    name: deviceSpec.name,
                    version: deviceSpec.version
                )
            }
        }
        
        let streamJSONPath = buildPath.stringByAppendingPathComponent("stream.json")
        
        func allTests() -> [Test]? {
            if exec(xctoolPath, "-workspace", workspace, "-scheme", scheme, "-sdk", "iphonesimulator", "CONFIGURATION_BUILD_DIR=\(buildPath)", "run-tests", "-listTestsOnly", "-only", target, "-reporter", "pretty", "-reporter", "json-stream:\(streamJSONPath)") != 0 {
                return nil
            } else {
                if let streamJSON = NSString(contentsOfFile: streamJSONPath, encoding: NSUTF8StringEncoding, error: nil) {
                    var tests: [Test] = []
                    
                    for line in streamJSON.componentsSeparatedByString("\n") {
                        if let lineData = line.dataUsingEncoding(NSUTF8StringEncoding) {
                            if let event = NSJSONSerialization.JSONObjectWithData(lineData, options: .allZeros, error: nil) as? NSDictionary {
                                if event["event"] as String == "begin-test" {
                                    tests.append(Test(className: event["className"] as String, methodName: event["methodName"] as String))
                                }
                            }
                        }
                    }
                    
                    return tests
                }
            }
            
            return nil
        }
        
        func xctoolArgumentFromTests(tests: [Test], inTarget target: String) -> String {
            return target + ":" + ",".join(tests.map { "\($0.className)/\($0.methodName)" })
        }
        
        func testFailuresByRunningTests(tests: [Test], onDestination destination: String) -> [Test] {
            NSFileManager.defaultManager().removeItemAtPath(streamJSONPath, error: nil)
            
            exec(xctoolPath, "-workspace", workspace, "-scheme", scheme, "-sdk", "iphonesimulator", "-destination", destination, "CONFIGURATION_BUILD_DIR=\(buildPath)", "run-tests", "-freshSimulator", "-resetSimulator", "-only", xctoolArgumentFromTests(tests, inTarget: target), "-reporter", "pretty", "-reporter", "json-stream:\(streamJSONPath)")
            
            if let streamJSON = NSString(contentsOfFile: streamJSONPath, encoding: NSUTF8StringEncoding, error: nil) {
                var testFailures: [Test] = tests
                
                for line in streamJSON.componentsSeparatedByString("\n") {
                    if let lineData = line.dataUsingEncoding(NSUTF8StringEncoding) {
                        if let event = NSJSONSerialization.JSONObjectWithData(lineData, options: .allZeros, error: nil) as? NSDictionary {
                            if event["event"] as String == "end-test" && (event["succeeded"] as NSNumber).boolValue == true {
                                testFailures.remove(Test(className: event["className"] as String, methodName: event["methodName"] as String))
                            }
                        }
                    }
                }
                
                return testFailures
            }
            
            return tests
        }
        
        printMessage("Getting the list of tests")
        if let allTests = allTests() {
            printMessage("Got the lists of tests")
            
            let partitionedTests = allTests.partition(numberOfPartitions)[partitionIndex]
            
            for test in allTests {
                let marker = (partitionedTests.contains(test) ? ">" : " ")
                println("\t\(marker) \(test.className).\(test.methodName)")
            }
            
            for device in devices() {
                var numberOfAttemptsWithoutProgress = 0
                
                var remainingTests = partitionedTests
                while !remainingTests.isEmpty && numberOfAttemptsWithoutProgress < maxNumberOfAttemptsWithoutProgress {
                    let attemptDescription = "attempt \(numberOfAttemptsWithoutProgress + 1)"
                    
                    printMessage("Running \(remainingTests.count) test(s) on \(device.description) (\(attemptDescription))")
                    for test in remainingTests {
                        println("\t> \(test.className).\(test.methodName)")
                    }
                    
                    let failedTests = testFailuresByRunningTests(remainingTests, onDestination: device.destination)
                    if !failedTests.isEmpty {
                        printMessage("\(failedTests.count) of \(remainingTests.count) test(s) FAILED on \(device.description) (\(attemptDescription))")
                    }
                    
                    if failedTests.count < remainingTests.count {
                        numberOfAttemptsWithoutProgress = 0
                    } else {
                        ++numberOfAttemptsWithoutProgress
                    }
                    
                    remainingTests = failedTests
                }
                
                if !remainingTests.isEmpty {
                    printMessage("Tests FAILED on \(device.description) too many times without progress")
                    exit(1)
                } else {
                    printMessage("Tests PASSED on \(device.description)")
                }
            }
        } else {
            printMessage("Failed to list tests")
            exit(1)
        }
        
        printMessage("All tests PASSED on all devices")
    default: ()
    }
}
