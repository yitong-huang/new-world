import Foundation

let listener = NSXPCListener(machServiceName: "com.newworld.NewWorldVPN.helper")
let delegate = HelperListener()
listener.delegate = delegate
listener.resume()
dispatchMain()
