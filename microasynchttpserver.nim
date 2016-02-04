import asyncdispatch
import asyncnet
import asynchttpserver
import strutils
import uri

when compileOption("threads"):
    import threadpool

import picohttpparser_api

const HTTP_HEADER_BUFFER_INITIAL_SIZE = 512

type
    MicroAsyncHttpServer* = ref tuple
        socket: AsyncSocket

proc newMicroAsyncHttpServer*(): MicroAsyncHttpServer =
    new(result)
    result.socket = newAsyncSocket()

proc processConnection(socket: AsyncSocket, hostname: string, callback: proc (request: Request): Future[void] {.closure,gcsafe.}) {.async.} =
    while not socket.isClosed:
        var httpMethod: string
        var path: string
        var minorVersion: cint

        var numberOfHeaders = 0
        var headerBuffer = newStringOfCap(HTTP_HEADER_BUFFER_INITIAL_SIZE)

        while true:
            let line = await socket.recvLine

            if line == "":
                if not socket.isClosed:
                    socket.close

                return

            if not (((line.len == 1) and (line[0] == char(0x0a))) or ((line.len == 2) and (line[0] == char(0x0d)) and (line[1] == char(0x0a)))):
                numberOfHeaders += 1

                headerBuffer.add(line)
                headerBuffer.add("\n")
            else:
                headerBuffer.add("\n")
                break

        var headers = newSeq[phr_header](numberOfHeaders)
        
        if tryParseRequest(headerBuffer, httpMethod, path, minorVersion, headers) >= 0:
            var request = Request(client: socket, reqMethod: httpMethod.toLower, headers: headers,
                                  protocol: (orig: "HTTP/1." & $minorVersion, major: 1, minor: int(minorVersion)), 
                                  url: parseUri(path), hostname: hostname, body: "")

            await callback(request)
        else:
            if not socket.isClosed:
                await socket.send("HTTP/1.0 400 Bad Request\r\nExpires: Thu, 01 Jan 1970 00:00:01 GMT\r\nContent-Length: 0\r\n\r\n")
                socket.close

proc serve*(server: MicroAsyncHttpServer, port: Port, callback: proc (request: Request): Future[void] {.closure,gcsafe.},
            address = "") {.async.} =

    server.socket.setSockOpt(OptReuseAddr, true)
    server.socket.bindAddr(port, address)
    server.socket.listen

    while true:
        let socket = await server.socket.acceptAddr

        try:
            when compileOption("threads"):
                spawn(asyncCheck socket.client.processConnection(socket.address, callback))
            else:
                asyncCheck socket.client.processConnection(socket.address, callback)
        except Exception:
            if not socket.client.isClosed:
                socket.client.close

            let e = getCurrentException()
            stderr.write(e.getStackTrace())
            stderr.write("Error: unhandled exception: ")
            stderr.writeLine(getCurrentExceptionMsg())
