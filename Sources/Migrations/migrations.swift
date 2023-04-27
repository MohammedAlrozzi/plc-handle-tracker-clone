import Fluent
import Vapor

func migrations(_ app: Application) {
  app.migrations.add(CreateDidsTable())
  app.migrations.add(CreateHandlesTable())
  app.migrations.add(CreatePersonalDataServersTable())
  app.migrations.add(CreateOperationsTable())
}