//
//  DataAccessObject.swift
//  AlbumoCore
//
//  Created by BJ Beecher on 1/25/26.
//

import Foundation
import VLSharedModels
import VLHTTP

public struct DataAccessor<T: Decodable>: Sendable {
    public var endpoint: HTTPEndpoint<T>
    public let cacheId: String?
    public var postActions: [@Sendable (DataService) async throws -> Void] = []
    
    public init(
        endpoint: HTTPEndpoint<T>,
        cacheId: String?,
        postActions: [@Sendable (DataService) async throws -> Void]
    ) {
        self.endpoint = endpoint
        self.cacheId = cacheId
        self.postActions = postActions
    }
}
