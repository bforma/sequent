# frozen_string_literal: true

module Sequent
  module Test
    module DatabaseHelpers
      class << self
        # Utility method to let Sequent handle creation of sequent_schema and view_schema
        # rather than using the available rake tasks.
        def maintain_test_database_schema(env: 'test')
          fail ArgumentError, "env must be test or spec but was '#{env}'" unless %w[test spec].include?(env)

          Migrations::SequentSchema.create_sequent_schema_if_not_exists(env: env, fail_if_exists: false)
          Migrations::ViewSchema.create_view_tables(env: env)
        end
      end
    end
  end
end
