//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation


#if os(Linux)
import Glibc
let sysWrite = Glibc.write
let sysWritev = Glibc.writev
let sysRead = Glibc.read
let sysConnect = Glibc.connect
#else
import Darwin
let sysWrite = Darwin.write
let sysWritev = Darwin.writev
let sysRead = Darwin.read
let sysConnect = Darwin.connect
#endif

public typealias IOVector = iovec

// TODO: scattering support
final class Socket : BaseSocket {
    static var writevLimit: Int {
// UIO_MAXIOV is only exported on linux atm
#if os(Linux)
        return Int(UIO_MAXIOV)
#else
        return 1024
#endif
    }
    
    init(protocolFamily: Int32) throws {
        let sock = try BaseSocket.newSocket(protocolFamily: protocolFamily)
        super.init(descriptor: sock)
    }
    
    override init(descriptor : Int32) {
        super.init(descriptor: descriptor)
    }
    
    func connect(to address: SocketAddress) throws  -> Bool {
        switch address {
        case .v4(address: let addr, _):
            return try connectSocket(addr: addr)
        case .v6(address: let addr, _):
            return try connectSocket(addr: addr)
        case .unixDomainSocket(address: let addr):
            return try connectSocket(addr: addr)
        }
    }
    
    private func connectSocket<T>(addr: T) throws -> Bool {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't connect socket as it's not open anymore.")
        }
        var addr = addr
        return try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                do {
                    let _ = try wrapSyscall({ $0 != -1 }, function: "connect") {
                        sysConnect(self.descriptor, ptr, socklen_t(MemoryLayout.size(ofValue: addr)))
                    }
                    return true
                } catch let err as IOError {
                    if err.errno == EINPROGRESS {
                        return false
                    }
                    throw err
                }
            }
        }
    }
    
    func finishConnect() throws {
        let result: Int32 = try getOption(level: SOL_SOCKET, name: SO_ERROR)
        if result != 0 {
            throw ioError(errno: result, function: "getsockopt")
        }
    }
    
    func write(data: Data) throws -> IOResult<Int> {
        return try data.withUnsafeBytes({ try write(pointer: $0, size: data.count) })
    }

    func write(pointer: UnsafePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't write to socket as it's not open anymore.")
        }
        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "write") {
            sysWrite(self.descriptor, pointer, size)
        }
    }

    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't writev to socket as it's not open anymore.")
        }

        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "writev") {
            sysWritev(self.descriptor, iovecs.baseAddress!, Int32(iovecs.count))
        }
    }
    
    func read(data: inout Data) throws -> IOResult<Int> {
        return try data.withUnsafeMutableBytes({ try read(pointer: $0, size: data.count) })
    }

    func read(pointer: UnsafeMutablePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't read from socket as it's not open anymore.")
        }

        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "read") {
            sysRead(self.descriptor, pointer, size)
        }
    }
    
    func sendFile(fd: Int32, offset: Int, count: Int) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't write to socket as it's not open anymore.")
        }
      
        var written: Int = 0
        
        do {
            let _ = try wrapSyscall({ $0 >= 0 }, function: "sendfile") {
                #if os(macOS)
                    var w: off_t = off_t(count)
                    let result = Int(Darwin.sendfile(fd, self.descriptor, off_t(offset), &w, nil, 0))
                    written = Int(w)
                    return result
                #else
                    var off: off_t = offset
                    let result = Glibc.sendfile(self.descriptor, fd, &off, count)
                    if result >= 0 {
                        written = result
                    } else {
                        written = 0
                    }
                    return result
                #endif
            }
            return .processed(written)
        } catch let err as IOError {
            if err.errno == EAGAIN {
                
                return .wouldBlock(written)
            }
            throw err
        }

    }
}