//
//  HTTPRequestInteceptor.swift
//  app-foundation
//
//  Created by BJ Beecher on 2/17/26.
//

import Foundation

public protocol HTTPServiceRequestInteceptor {
    func intercept<T: Decodable>(_ request: inout HTTPEndpoint<T>) async throws
}
