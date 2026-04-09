// Sources/JMTerm/Services/RSASha512.swift
// rsa-sha2-512 알고리즘 구현 (최신 OpenSSH 서버 호환)
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Citadel
import Crypto
import CCryptoBoringSSL

// MARK: - RSA SHA-512 Public Key

final class RSASHA512PublicKey: NIOSSHPublicKeyProtocol, @unchecked Sendable {
    static let publicKeyPrefix = "rsa-sha2-512"

    let e: UnsafeMutablePointer<BIGNUM>
    let n: UnsafeMutablePointer<BIGNUM>

    var rawRepresentation: Data {
        var buffer = ByteBuffer()
        writeMPBignum(e, to: &buffer)
        writeMPBignum(n, to: &buffer)
        return Data(buffer.readableBytesView)
    }

    init(e: UnsafeMutablePointer<BIGNUM>, n: UnsafeMutablePointer<BIGNUM>) {
        self.e = e
        self.n = n
    }

    deinit {
        CCryptoBoringSSL_BN_free(e)
        CCryptoBoringSSL_BN_free(n)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let sig = signature as? RSASHA512Signature else { return false }

        let ctx = CCryptoBoringSSL_RSA_new()
        defer { CCryptoBoringSSL_RSA_free(ctx) }

        let eCopy = CCryptoBoringSSL_BN_dup(e)
        let nCopy = CCryptoBoringSSL_BN_dup(n)
        guard CCryptoBoringSSL_RSA_set0_key(ctx, nCopy, eCopy, nil) == 1 else { return false }

        let hash = Array(SHA512.hash(data: data))
        let sigBytes = Array(sig.rawRepresentation)
        return CCryptoBoringSSL_RSA_verify(
            NID_sha512, hash, hash.count,
            sigBytes, sigBytes.count, ctx
        ) == 1
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        writeMPBignum(e, to: &buffer) + writeMPBignum(n, to: &buffer)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512PublicKey {
        guard let eLen = buffer.readInteger(as: UInt32.self),
              let eBytes = buffer.readBytes(length: Int(eLen)),
              let nLen = buffer.readInteger(as: UInt32.self),
              let nBytes = buffer.readBytes(length: Int(nLen)) else {
            throw SSHSessionError.invalidKeyFormat
        }
        let eBN = CCryptoBoringSSL_BN_bin2bn(eBytes, eBytes.count, nil)!
        let nBN = CCryptoBoringSSL_BN_bin2bn(nBytes, nBytes.count, nil)!
        return RSASHA512PublicKey(e: eBN, n: nBN)
    }
}

// MARK: - RSA SHA-512 Signature

struct RSASHA512Signature: NIOSSHSignatureProtocol, ContiguousBytes, Sendable {
    static let signaturePrefix = "rsa-sha2-512"

    let rawRepresentation: Data

    init(rawRepresentation: Data) {
        self.rawRepresentation = rawRepresentation
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try rawRepresentation.withUnsafeBytes(body)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        let len = buffer.writeInteger(UInt32(rawRepresentation.count))
        return len + buffer.writeBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512Signature {
        guard let len = buffer.readInteger(as: UInt32.self),
              let data = buffer.readData(length: Int(len)) else {
            throw SSHSessionError.invalidKeyFormat
        }
        return RSASHA512Signature(rawRepresentation: data)
    }
}

// MARK: - RSA SHA-512 Private Key

final class RSASHA512PrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static let keyPrefix = "rsa-sha2-512"

    let d: UnsafeMutablePointer<BIGNUM>
    let e: UnsafeMutablePointer<BIGNUM>
    let n: UnsafeMutablePointer<BIGNUM>

    var publicKey: NIOSSHPublicKeyProtocol {
        RSASHA512PublicKey(e: CCryptoBoringSSL_BN_dup(e)!, n: CCryptoBoringSSL_BN_dup(n)!)
    }

    init(d: UnsafeMutablePointer<BIGNUM>, e: UnsafeMutablePointer<BIGNUM>, n: UnsafeMutablePointer<BIGNUM>) {
        self.d = d
        self.e = e
        self.n = n
    }

    deinit {
        CCryptoBoringSSL_BN_free(d)
        CCryptoBoringSSL_BN_free(e)
        CCryptoBoringSSL_BN_free(n)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let ctx = CCryptoBoringSSL_RSA_new()
        defer { CCryptoBoringSSL_RSA_free(ctx) }

        let nCopy = CCryptoBoringSSL_BN_dup(n)
        let eCopy = CCryptoBoringSSL_BN_dup(e)
        let dCopy = CCryptoBoringSSL_BN_dup(d)
        guard CCryptoBoringSSL_RSA_set0_key(ctx, nCopy, eCopy, dCopy) == 1 else {
            throw CitadelError.signingError
        }

        let hash = Array(SHA512.hash(data: data))
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { out.deallocate() }
        var outLength: UInt32 = 4096
        guard CCryptoBoringSSL_RSA_sign(
            NID_sha512, hash, hash.count,
            out, &outLength, ctx
        ) == 1 else {
            throw CitadelError.signingError
        }

        return RSASHA512Signature(rawRepresentation: Data(bytes: out, count: Int(outLength)))
    }
}

// MARK: - Auth Delegate

final class RSASHA512AuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: RSASHA512PrivateKey
    private var offered = false

    init(username: String, d: UnsafeMutablePointer<BIGNUM>, e: UnsafeMutablePointer<BIGNUM>, n: UnsafeMutablePointer<BIGNUM>) {
        self.username = username
        self.privateKey = RSASHA512PrivateKey(d: d, e: e, n: n)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true

        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }

        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: .init(custom: privateKey)))
        ))
    }
}

// MARK: - Helper

@discardableResult
private func writeMPBignum(_ bn: UnsafeMutablePointer<BIGNUM>, to buffer: inout ByteBuffer) -> Int {
    let numBytes = Int(CCryptoBoringSSL_BN_num_bytes(bn))
    var bytes = [UInt8](repeating: 0, count: numBytes)
    CCryptoBoringSSL_BN_bn2bin(bn, &bytes)
    let needsPadding = !bytes.isEmpty && (bytes[0] & 0x80) != 0
    let totalLen = needsPadding ? numBytes + 1 : numBytes
    var written = buffer.writeInteger(UInt32(totalLen))
    if needsPadding { written += buffer.writeInteger(UInt8(0)) }
    written += buffer.writeBytes(bytes)
    return written
}

/// NIOSSH에 rsa-sha2-512 알고리즘을 등록합니다.
func registerRSASHA512() {
    NIOSSHAlgorithms.register(publicKey: RSASHA512PublicKey.self, signature: RSASHA512Signature.self)
}
