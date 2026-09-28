import Foundation

enum DicomWebSTOWMultipartBodyBuilder {
    struct PreparedInstance {
        var data: Data
        var contentType: String
        var transferSyntax: String?
    }

    static func build(instances: [DicomWebStoreInstance], boundary: String, maximumBytes: Int) throws -> Data {
        let preparedInstances = try prepare(instances: instances)
        let bodyByteCount = try serializedByteCount(
            preparedInstances: preparedInstances,
            boundary: boundary,
            maximumBytes: maximumBytes
        )
        try Task.checkCancellation()
        var body = Data()
        body.reserveCapacity(bodyByteCount)
        var writer = try DicomWebMultipartStreamWriter(boundary: boundary, maximumBytes: maximumBytes)
        for instance in preparedInstances {
            let type = instance.contentType + (instance.transferSyntax.map { "; transfer-syntax=\($0)" } ?? "")
            try writer.beginPart(headers: [("Content-Type", type)], contentLength: instance.data.count) { body.append($0) }
            try writer.payload(instance.data) { body.append($0) }
            try writer.endPart { body.append($0) }
        }
        try writer.finish { body.append($0) }
        return body
    }

    static func serializedByteCount(
        instances: [DicomWebStoreInstance],
        boundary: String,
        maximumBytes: Int
    ) throws -> Int {
        try Task.checkCancellation()
        let preparedInstances = try prepare(instances: instances)
        return try serializedByteCount(
            preparedInstances: preparedInstances,
            boundary: boundary,
            maximumBytes: maximumBytes
        )
    }

    private static func serializedByteCount(
        preparedInstances: [PreparedInstance],
        boundary: String,
        maximumBytes: Int
    ) throws -> Int {
        let boundaryByteCount = boundary.utf8.count
        let partHeaderPrefixSuffixByteCount = "\r\nContent-Type: ".utf8.count
        let transferSyntaxPrefixByteCount = "; transfer-syntax=".utf8.count
        let contentLengthPrefixByteCount = "\r\nContent-Length: ".utf8.count
        let headerTerminatorByteCount = "\r\n\r\n".utf8.count
        let partTerminatorByteCount = "\r\n".utf8.count
        let closingBoundarySuffixByteCount = "--\r\n".utf8.count
        var bodyByteCount = 0
        try add(2, to: &bodyByteCount)
        try add(boundaryByteCount, to: &bodyByteCount)
        try add(closingBoundarySuffixByteCount, to: &bodyByteCount)

        for instance in preparedInstances {
            try Task.checkCancellation()
            try add(2, to: &bodyByteCount)
            try add(boundaryByteCount, to: &bodyByteCount)
            try add(partHeaderPrefixSuffixByteCount, to: &bodyByteCount)
            try add(instance.contentType.utf8.count, to: &bodyByteCount)
            if let transferSyntax = instance.transferSyntax {
                try add(transferSyntaxPrefixByteCount, to: &bodyByteCount)
                try add(transferSyntax.utf8.count, to: &bodyByteCount)
            }
            try add(contentLengthPrefixByteCount, to: &bodyByteCount)
            try add(String(instance.data.count).utf8.count, to: &bodyByteCount)
            try add(headerTerminatorByteCount, to: &bodyByteCount)
            try add(instance.data.count, to: &bodyByteCount)
            try add(partTerminatorByteCount, to: &bodyByteCount)
        }
        guard bodyByteCount <= maximumBytes else {
            throw DicomWebClientError.storeRequestBodyTooLarge(
                byteCount: bodyByteCount,
                limit: maximumBytes
            )
        }
        return bodyByteCount
    }

    static func prepare(instances: [DicomWebStoreInstance]) throws -> [PreparedInstance] {
        var preparedInstances: [PreparedInstance] = []
        preparedInstances.reserveCapacity(instances.count)

        for (index, instance) in instances.enumerated() {
            try Task.checkCancellation()
            guard isApplicationDicomMediaType(instance.contentType) else {
                throw DicomWebClientError.invalidStoreContentType(instanceIndex: index)
            }
            if let transferSyntax = instance.transferSyntax,
               !isValidUID(transferSyntax) {
                throw DicomWebClientError.invalidStoreTransferSyntaxUID(instanceIndex: index)
            }

            var effectiveTransferSyntax = instance.transferSyntax
            if DicomPart10FileMetaParser.hasPart10Prefix(instance.data) {
                let fileMeta: DicomPart10FileMetaParser.FileMeta
                do {
                    fileMeta = try DicomPart10FileMetaParser.parse(instance.data)
                } catch {
                    throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
                }
                guard let fileMetaTransferSyntax = fileMeta.transferSyntaxUID,
                      isValidUID(fileMetaTransferSyntax) else {
                    throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
                }
                if let suppliedTransferSyntax = instance.transferSyntax,
                   suppliedTransferSyntax != fileMetaTransferSyntax {
                    throw DicomWebClientError.storeTransferSyntaxMismatch(instanceIndex: index)
                }
                effectiveTransferSyntax = fileMetaTransferSyntax
            }

            preparedInstances.append(PreparedInstance(
                data: instance.data,
                contentType: instance.contentType,
                transferSyntax: effectiveTransferSyntax
            ))
        }
        return preparedInstances
    }

    private static func isApplicationDicomMediaType(_ value: String) -> Bool {
        let expected = "application/dicom".utf8
        guard value.utf8.count == expected.count else {
            return false
        }
        return zip(value.utf8, expected).allSatisfy { actual, expected in
            let lowercaseASCII = (65...90).contains(actual) ? actual + 32 : actual
            return lowercaseASCII == expected
        }
    }

    private static func isValidUID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 64 else {
            return false
        }

        var componentLength = 0
        var componentStartsWithZero = false
        for byte in bytes {
            if byte == 46 {
                guard componentLength > 0,
                      !(componentStartsWithZero && componentLength > 1) else {
                    return false
                }
                componentLength = 0
                componentStartsWithZero = false
            } else {
                guard (48...57).contains(byte) else {
                    return false
                }
                if componentLength == 0 {
                    componentStartsWithZero = byte == 48
                }
                componentLength += 1
            }
        }
        return componentLength > 0 && !(componentStartsWithZero && componentLength > 1)
    }

    static func add(_ componentByteCount: Int, to totalByteCount: inout Int) throws {
        let (sum, overflow) = totalByteCount.addingReportingOverflow(componentByteCount)
        guard !overflow else {
            throw DicomWebClientError.multipartBodyTooLarge
        }
        totalByteCount = sum
    }
}
