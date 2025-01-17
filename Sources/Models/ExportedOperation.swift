import Fluent
import FluentPostgresDriver
import Foundation
import Vapor

enum OpType: String, Decodable {
  case create
  case plcOperation = "plc_operation"
  case plcTombstone = "plc_tombstone"
}

protocol CompatibleOperationOrTombstone {
  var sig: String { get }
  var type: OpType { get }
  var prev: String? { get }
}

struct PlcOperation: CompatibleOperationOrTombstone {
  let sig: String
  var type: OpType { return OpType.plcOperation }
  let prev: String?

  let services: Services

  let alsoKnownAs: [String]
  let rotationKeys: [String]

  struct VerificationMethods: Decodable {
    var atproto: String
  }
  let verificationMethods: VerificationMethods
}
struct Services: Decodable {
  struct AtprotoPds: Decodable {
    var type: String = "AtprotoPersonalDataServer"
    var endpoint: String
  }
  var atprotoPds: AtprotoPds

  enum CodingKeys: String, CodingKey {
    case atprotoPds = "atproto_pds"
  }
}

struct CreateOperation: CompatibleOperationOrTombstone {
  let sig: String
  var type: OpType { return OpType.create }
  var prev: String? { return nil }

  let handle: String
  let service: String
  let signingKey: String
  let recoveryKey: String
}

struct PlcTombstone: CompatibleOperationOrTombstone {
  let sig: String
  var type: OpType { return OpType.plcTombstone }
  let prev: String?
}

struct ExportedOperation: Decodable {
  var did: String
  var operation: CompatibleOperationOrTombstone
  var cid: String
  var nullified: Bool
  var createdAt: Date

  private struct GenericOperaion: Decodable {
    let sig: String
    let type: OpType
    let prev: String?

    let handle: String?
    let service: String?
    let signingKey: String?
    let recoveryKey: String?

    let services: Services?
    let alsoKnownAs: [String]?
    let rotationKeys: [String]?
    let verificationMethods: PlcOperation.VerificationMethods?
  }

  enum CodingKeys: String, CodingKey {
    case did
    case operation
    case cid
    case nullified
    case createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.did = try container.decode(String.self, forKey: .did)
    self.cid = try container.decode(String.self, forKey: .cid)
    self.nullified = try container.decode(Bool.self, forKey: .nullified)
    self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    let operation = try container.decode(GenericOperaion.self, forKey: .operation)
    self.operation = {
      switch operation.type {
      case .create:
        // It's OK to force unwrap here because we already
        // know what type the item object is
        return CreateOperation(
          sig: operation.sig, handle: operation.handle!, service: operation.service!,
          signingKey: operation.signingKey!, recoveryKey: operation.recoveryKey!)
      case .plcOperation:
        return PlcOperation(
          sig: operation.sig, prev: operation.prev, services: operation.services!,
          alsoKnownAs: operation.alsoKnownAs!, rotationKeys: operation.rotationKeys!,
          verificationMethods: operation.verificationMethods!)
      case .plcTombstone:
        return PlcTombstone(sig: operation.sig, prev: operation.prev!)
      }
    }()
  }

  func normalize(on database: Database) async throws -> Operation {
    let did = try await self.resolve(did: self.did, on: database)
    switch self.operation.type {
    case .create:
      guard let createOp = self.operation as? CreateOperation else {
        throw "Invalid operation type"
      }
      async let handle = self.resolve(handle: createOp.handle, on: database)
      async let pds = self.resolve(serviceEndpoint: createOp.service, on: database)
      return try Operation(
        cid: self.cid, did: did, nullified: self.nullified,
        createdAt: self.createdAt, handle: try await handle, pds: try await pds)
    case .plcOperation:
      guard let plcOp = self.operation as? PlcOperation else {
        throw "Invalid operation type"
      }
      guard
        let handleString = plcOp.alsoKnownAs.first(where: { $0.hasPrefix("at://") })?
          .replacingOccurrences(of: "at://", with: "")
      else {
        throw "Not found handle"
      }
      let prev = try await { (_ cid: String?) -> Operation? in
        guard let cid else {
          return nil
        }
        return try await self.resolve(prev: cid, on: database)
      }(plcOp.prev)
      async let handle = self.resolve(handle: handleString, on: database)
      async let pds = self.resolve(
        serviceEndpoint: plcOp.services.atprotoPds.endpoint, on: database)
      return try Operation(
        cid: self.cid, did: did, nullified: self.nullified, createdAt: self.createdAt, prev: prev,
        handle: try await handle, pds: try await pds)
    case .plcTombstone:
      guard let tombstoneOp = self.operation as? PlcTombstone else {
        throw "Invalid operation type"
      }
      let prev = try await self.resolve(prev: tombstoneOp.prev!, on: database)
      return try Operation(
        cid: self.cid, did: did, nullified: self.nullified,
        createdAt: self.createdAt, prev: prev)
    }
  }

  func resolve(did string: String, on database: Database) async throws -> Did {
    guard let did = try await Did.find(string, on: database) else {
      let did = Did(did: string)
      do {
        try await did.create(on: database)
      } catch let error as PostgresError where error.code == .uniqueViolation {
        return try await self.resolve(did: string, on: database)
      } catch {
        throw error
      }
      return did
    }
    return did
  }

  func resolve(handle string: String, on database: Database) async throws -> Handle {
    guard let handle = try await Handle.query(on: database).filter(\.$handle == string).first()
    else {
      let handle = Handle(handle: string)
      do {
        try await handle.create(on: database)
      } catch let error as PostgresError where error.code == .uniqueViolation {
        return try await self.resolve(handle: string, on: database)
      } catch {
        throw error
      }
      return handle
    }
    return handle
  }

  func resolve(serviceEndpoint string: String, on database: Database) async throws
    -> PersonalDataServer
  {
    guard
      let service = try await PersonalDataServer.query(on: database).filter(\.$endpoint == string)
        .first()
    else {
      let service = PersonalDataServer(endpoint: string)
      do {
        try await service.create(on: database)
      } catch let error as PostgresError where error.code == .uniqueViolation {
        return try await self.resolve(serviceEndpoint: string, on: database)
      } catch {
        throw error
      }
      return service
    }
    return service
  }

  func resolve(prev cid: String, on database: Database) async throws -> Operation? {
    guard let operation = try await Operation.find(cid, on: database) else {
      throw "Unknown operation"
    }
    return operation
  }
}
