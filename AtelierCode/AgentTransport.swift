//
//  AgentTransport.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

@MainActor
protocol AgentTransport: AnyObject {
    var onReceive: ((Result<Data, any Error>) -> Void)? { get set }

    func start() throws
    func stop()
    func send(message: Data) throws
}
