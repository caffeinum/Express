//===--- HttpServer.swift -------------------------------------------------===//
//
//Copyright (c) 2015-2016 Daniel Leping (dileping)
//
//This file is part of Swift Express.
//
//Swift Express is free software: you can redistribute it and/or modify
//it under the terms of the GNU Lesser General Public License as published by
//the Free Software Foundation, either version 3 of the License, or
//(at your option) any later version.
//
//Swift Express is distributed in the hope that it will be useful,
//but WITHOUT ANY WARRANTY; without even the implied warranty of
//MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//GNU Lesser General Public License for more details.
//
//You should have received a copy of the GNU Lesser General Public License
//along with Swift Express.  If not, see <http://www.gnu.org/licenses/>.
//
//===----------------------------------------------------------------------===//

import Foundation
import Result
import Future
#if os(Linux)
    import Glibc
#endif
import ExecutionContext

private class ServerParams {
    let promise: Promise<Void>
    let port: UInt16
    let app:Express
    
    init(promise: Promise<Void>, port: UInt16, app: Express) {
        self.promise = promise
        self.port = port
        self.app = app
    }
}

private class ResponseDataConsumer : ResponseHeadDataConsumerType {
    let sock:EVHTPRequest
    var buffer: EVHTPBuffer?
    
    init(sock: EVHTPRequest) {
        self.sock = sock
        self.buffer = nil
    }
    
    func consume(head: HttpResponseHeadType) -> Future<Void> {
        //TODO: handle errors if any
        if let h = head as? HttpResponseHead {
            buffer = EVHTP.start_response(req: sock, headers: h.headers, status: h.status)
        } else {
            buffer = EVHTP.start_response(req: sock, headers: Dictionary<String, String>(), status: head.status)
        }
        return Future(value: ())
    }
    
    func consume(data:Array<UInt8>) -> Future<Void> {
        //TODO: handle errors if any
        buffer?.write(data: data)
        return Future(value: ())
    }
    
    func dataEnd() throws {
        //TODO: handle errors if any
        EVHTP.finish_response(req: sock, buffer: buffer!)
        buffer = nil
    }
}

private func handle_request(req: EVHTPRequest, serv:ServerParams) {
    //TODO: implement request data parsing
    
    let info = EVHTP.get_request_info(req: req)
    let head = RequestHead(app: serv.app, method: info.method, version: info.version, remoteAddress: info.remoteIp, secure: info.scheme == "HTTPS", uri: info.uri, path: info.path, query: info.query, headers: info.headers, params: Dictionary())
    let os = ResponseDataConsumer(sock: req)
    
    let routeTuple = serv.app.firstRoute(request: head)
    let transaction = routeTuple.map {
        ($0.0, head.withParams(params: $0.1, app: serv.app))
    }.map { ( route, header) in
        route.factory(header, os)
    }
        
        
    /*    .getOrElse(Transaction(app: serv.app, routeId: "", head: head, out: os))
    
    let route = routeTuple.0
    let header = head.withParams(routeTuple.1)*/
    
    if let transaction = transaction {
        transaction.selfProcess()
        EVHTP.read_data(req: req, cb: { data in
            if data.count > 0 {
                //TODO: handle consumption success or error
                transaction.consume(data: data)
            } else {
                //TODO: handle errors (for now silencing it with try!)
                try! transaction.dataEnd()
            }
            return true
        })
    } else {
        let transaction = Transaction<AnyContent, AnyContent>(app: serv.app, routeId: "", head: head, out: os)
        let action = future(context: immediate) { () throws -> AbstractActionType in
            throw ExpressError.RouteNotFound(path: head.path)
        }
        transaction.handleAction(action: action, request: Optional<Request<AnyContent>>.none)
        try! transaction.dataEnd()
    }
}

private func server_thread(pm: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let serv = Unmanaged<ServerParams>.fromOpaque(pm).takeRetainedValue()
    let base = EVHTP.create_base()
    let htp_serv = EVHTP.create_htp(base: base)
    EVHTP.bind_address(htp: htp_serv, host: "0.0.0.0", port: serv.port)
    
    EVHTP.add_general_route(htp: htp_serv) { (req: EVHTPRequest) -> () in
        
        
        handle_request(req: req, serv: serv)
    }
    
    serv.promise.completeWith(future: EVHTP.start_event(base: base))
    
    EVHTP.start_server_loop(base: base)
    return nil
}

class HttpServer : ServerType {
    let port:UInt16
    let app:Express
    let thread: UnsafeMutablePointer<pthread_t?>
    
    func start() -> Future<ServerType> {
        let params = ServerParams(promise: Promise<Void>(context: ExecutionContext.network), port: port, app: app)
        
        
        pthread_create(thread, nil, server_thread, UnsafeMutableRawPointer(Unmanaged.passRetained(params).toOpaque()))
        return params.promise.future.map {
            self
        }
    }
    
    required init(app:Express, port:UInt16) {
        self.port = port
        self.app = app
        self.thread = UnsafeMutablePointer<pthread_t?>.allocate(capacity: 1)
    }
    
    deinit {
        self.thread.deinitialize()
        self.thread.deallocate(capacity: 1)
    }
}
