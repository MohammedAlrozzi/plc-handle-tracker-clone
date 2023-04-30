import Fluent
import Vapor

struct HandleResponse: Content {
  struct UpdateHandleOperation: Content {
    let did: String
    let pds: String
    let createdAt: Date
    let updatedAt: Date?
  }

  struct Current: Content {
    let did: String
    let pds: String

    init?(op operation: UpdateHandleOperation?) {
      guard let operation, operation.updatedAt == nil else {
        return nil
      }
      self.did = operation.did
      self.pds = operation.pds
    }
  }

  let handle: String
  let current: Current?
  let operations: [UpdateHandleOperation]
}

struct HandleController: RouteCollection {
  func boot(routes: RoutesBuilder) throws {
    let handles = routes.grouped("handle")
    handles.get(use: index)
    handles.group(":handle") { handle in
      handle.get(use: show)
    }
  }

  func index(req: Request) async throws -> [Handle] {
    try await Handle.query(on: req.db).all()
  }

  func show(req: Request) async throws -> View {
    guard let handleName = req.parameters.get("handle") else {
      throw Abort(.internalServerError)
    }
    guard
      let handle = try await Handle.query(on: req.db).filter(\.$handle == handleName).with(
        \.$operations,
        { operations in
          operations.with(\.$pds).with(\.$did) { did in
            did.with(\.$operations) { operations in operations.with(\.$handle) }
          }
        }
      ).first()
    else {
      throw Abort(.notFound)
    }
    let operations = try mergeSort(handle.operations).compactMap {
      operation -> HandleResponse.UpdateHandleOperation? in
      guard let didOps = try treeSort(operation.did.operations).first else {
        throw "Broken operation tree"
      }
      let updateHandleOps = try onlyUpdateHandle(op: didOps)
      guard let since = updateHandleOps.firstIndex(where: { $0.id == operation.id }) else {
        return nil
      }
      var until: Operation? = nil
      if since < updateHandleOps.indices.last! {
        until = updateHandleOps[since + 1]
      }
      return .init(
        did: operation.did.did, pds: operation.pds!.endpoint, createdAt: operation.createdAt,
        updatedAt: until?.createdAt)
    }
    let res = HandleResponse(
      handle: handle.handle, current: .init(op: operations.last), operations: operations)
    return try await req.view.render("handle/show", res)
  }
}
