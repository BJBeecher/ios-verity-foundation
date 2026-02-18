//
//  httpService.swift
//  TapTap
//
//  Created by BJ Beecher on 9/18/23.
//

import Combine
import Dependencies
import VLExtensions
import Foundation
import VLSharedModels
import VLFiles
import VLLogging

public enum APIServiceFailure: Error {
    case badStatusCode(Int)
}

public protocol HTTPService: Sendable {
    var unauthorizedPublisher: PassthroughSubject<Void, Never> { get }
    
    func callLoadState<Output: Decodable>(endpoint: HTTPEndpoint<Output>) async -> LoadState<Output>
    
    func data(from url: URL) async throws -> Data
    func download(from endpoint: URL) async throws -> URL
    func upload(to endpoint: URL, from file: File) async throws
    @discardableResult func multipartUpload<Output: Decodable>(
        to endpoint: HTTPEndpoint<Output>,
        content: [MultipartContent],
        onProgress: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> Output
    @discardableResult func multipartUpload<Output: Decodable>(to endpoint: HTTPEndpoint<Output>, content: [MultipartContent]) async throws -> Output
    @discardableResult func call<Output: Decodable>(endpoint: HTTPEndpoint<Output>) async throws -> Output
}

public extension HTTPService {
    @discardableResult func multipartUpload<Output: Decodable>(
        to endpoint: HTTPEndpoint<Output>,
        content: [MultipartContent]
    ) async throws -> Output {
        try await multipartUpload(to: endpoint, content: content, onProgress: { _ in })
    }
}

public final class APIServiceLiveValue: HTTPService, @unchecked Sendable {
    @Dependency(\.fileService) private var fileService
    @Dependency(\.loggingService) private var loggingService
    
    private let session: URLSession
    public let unauthorizedPublisher = PassthroughSubject<Void, Never>()
    
    init(
        session: URLSession = .shared
    ) {
        self.session = session
    }
}

// MARK: Public Methods

public extension APIServiceLiveValue {
    func download(from endpoint: URL) async throws -> URL {
        let request = URLRequest(url: endpoint)
        let (url, response) = try await session.download(for: request)
        try checkForServerError(response: response)
        return url
    }
    
    func upload(to endpoint: URL, from file: File) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue(file.contentType.headerValue, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: file.url)
        try checkForServerError(response: response)
    }
    
    func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try checkForServerError(response: response)
        return data
    }
    
    func multipartUpload<Output: Decodable>(
        to endpoint: HTTPEndpoint<Output>,
        content: [MultipartContent],
        onProgress: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> Output {
        let intercepted = try await intercept(endpoint: endpoint)
        var request = try intercepted.request()
        let multipartBoundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(multipartBoundary)", forHTTPHeaderField: "Content-Type")
        let tempFile = try await fileService.createFile(data: Data(), contentType: .multipart)
        let fileHandle = try FileHandle(forUpdating: tempFile.url)
        
        for item in content {
            var header = ""
            header.append("--\(multipartBoundary)\r\n")
            header.append("Content-Disposition: form-data; name=\"\(item.name)\"")
            
            if case .file(let file) = item.source {
                header.append("; filename=\"\(file.url.lastPathComponent)\"\r\n")
            } else {
                header.append("\r\n")
            }
            
            header.append("Content-Type: \(item.contentType)\r\n\r\n")
            
            if let headerData = header.data(using: .utf8) {
                try fileHandle.write(contentsOf: headerData)
            }
            
            let contentData: Data = switch item.source {
            case .file(let file):
                try Data(contentsOf: file.url)
            case .json(let object):
                try endpoint.encoder.encode(object)
            }
            
            try fileHandle.write(contentsOf: contentData)
            
            if let lineBreak = "\r\n".data(using: .utf8) {
                try fileHandle.write(contentsOf: lineBreak)
            }
        }
        
        if let closing = "--\(multipartBoundary)--\r\n".data(using: .utf8) {
            try fileHandle.write(contentsOf: closing)
        }
        
        try fileHandle.close()
        
        let uploadDelegate = UploadTaskDelegate()
        let progressCancellable = uploadDelegate.progressPublisher.sink { progress in
            onProgress(progress)
        }
        let uploadSession = URLSession(configuration: .default, delegate: uploadDelegate, delegateQueue: nil)
        defer {
            progressCancellable.cancel()
            uploadSession.invalidateAndCancel()
        }
        
        let (data, response) = try await uploadSession.upload(for: request, fromFile: tempFile.url)
        try await fileService.delete(file: tempFile)
        return try handleResponse(data: data, response: response, decoder: endpoint.decoder)
    }
    
    func callLoadState<Output: Decodable>(endpoint: HTTPEndpoint<Output>) async -> LoadState<Output> {
        do {
            let output: Output = try await call(endpoint: endpoint)
            return .success(output)
        } catch {
            return .failure(error)
        }
    }
    
    @discardableResult
    func call<Output: Decodable>(endpoint: HTTPEndpoint<Output>) async throws -> Output {
        let request = try endpoint.request()
        let (data, response) = try await session.data(for: request)
        return try handleResponse(data: data, response: response, decoder: endpoint.decoder)
    }
}

// MARK: Private methods

private extension APIServiceLiveValue {
    func intercept<T: Decodable>(endpoint:  HTTPEndpoint<T>) async throws -> HTTPEndpoint<T> {
        var new = endpoint
        
        for inteceptor in endpoint.intecepters {
            try await inteceptor.intercept(&new)
        }
        
        return new
    }
    
    func checkForServerError(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GenericError(message: "http response not in right format")
        }
        
        let statusCode = httpResponse.statusCode
        
        if statusCode == 401 {
            unauthorizedPublisher.send()
        }
        
        switch statusCode {
        case 200...299:
            return
        default:
            throw APIServiceFailure.badStatusCode(statusCode)
        }
    }
    
    func handleResponse<Output: Decodable>(data: Data, response: URLResponse, decoder: JSONDecoder) throws -> Output {
        try checkForServerError(response: response)
        
        if Output.self == EmptyResponse.self {
            return EmptyResponse() as! Output
        } else if Output.self == AttributedString.self {
            let string = try AttributedString(markdown: data, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return string as! Output
        } else {
            return try decoder.decode(Output.self, from: data)
        }
    }
}

// MARK: Preview

final class APIServicePreviewValue: HTTPService, @unchecked Sendable {
    func data(from url: URL) async throws -> Data {
        throw GenericError(message: "Not in use")
    }
    
    let unauthorizedPublisher = PassthroughSubject<Void, Never>()
    
    func upload(to endpoint: URL, from file: File) async throws {}
    
    func multipartUpload<Output>(
        to endpoint: HTTPEndpoint<Output>,
        content: [MultipartContent],
        onProgress: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> Output where Output : Decodable {
        throw GenericError(message: "Not in use")
    }
    
    func download(from endpoint: URL) async throws -> URL {
        throw GenericError(message: "Not in use")
    }
    
    func callLoadState<Output: Decodable>(endpoint: HTTPEndpoint<Output>) async -> LoadState<Output> { .loading }
    
    func call<Output: Decodable>(endpoint: HTTPEndpoint<Output>) async throws -> Output {
        throw GenericError(message: "Not in use")
    }
}

// MARK: Dependency

public enum APIServiceKey: DependencyKey {
    public static let liveValue: HTTPService = APIServiceLiveValue()
    public static let previewValue: HTTPService = APIServicePreviewValue()
}

public extension DependencyValues {
    var apiService: HTTPService {
        get { self[APIServiceKey.self] }
        set { self[APIServiceKey.self] = newValue }
    }
}
