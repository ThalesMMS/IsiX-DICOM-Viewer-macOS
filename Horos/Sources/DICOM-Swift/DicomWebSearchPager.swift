// Modified for Horos by Thales Matheus M Santos (ThalesMMS), 2026: a page
// holds the DICOM JSON objects as JSONSerialization reads them instead of
// DicomData data sets, and the response's Content-Type.
// Original: DICOM-Swift, DicomCore/DicomWebSearchPager.swift, revision 1947fefa46e6.
// Licensed under the Apache License, Version 2.0; see LICENSE in this folder.

import Foundation

public struct DicomWebSearchPage: @unchecked Sendable {
    /// The DICOM JSON objects of the page, as JSONSerialization reads them.
    public let records: [[String: Any]]
    public let statusCode: Int
    public let contentType: String?
    public let warning: String?
    public let offset: Int
    public let limit: Int?
    public var hasMore: Bool {
        guard let warning else { return false }
        let lower = warning.lowercased()
        return lower.contains("299") && (lower.contains("additional results") || lower.contains("truncat"))
    }
}

public struct DicomWebSearchPager: AsyncSequence, Sendable {
    public typealias Element = DicomWebSearchPage
    let client: DicomWebClient
    let parameters: DicomWebSearchParameters
    let continuesOnFullPage: Bool
    public func makeAsyncIterator() -> AsyncIterator { .init(client: client, parameters: parameters, continuesOnFullPage: continuesOnFullPage) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let client: DicomWebClient
        var parameters: DicomWebSearchParameters
        let continuesOnFullPage: Bool
        var finished = false
        public mutating func next() async throws -> DicomWebSearchPage? {
            try Task.checkCancellation()
            guard !finished else { return nil }
            let page = try await client.search(parameters: parameters)
            let fullPage = continuesOnFullPage && parameters.limit.map { $0 > 0 && page.records.count == $0 } == true
            finished = (!page.hasMore && !fullPage) || page.records.isEmpty || parameters.limit == 0
            let nextOffset = page.offset.addingReportingOverflow(page.records.count)
            guard !nextOffset.overflow else { throw DicomWebError(kind: .badRequest) }
            parameters.offset = nextOffset.partialValue
            return page
        }
    }
}
