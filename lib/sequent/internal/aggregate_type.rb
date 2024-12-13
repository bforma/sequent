# frozen_string_literal: true

require 'active_record'
require_relative '../application_record'

module Sequent
  module Internal
    class AggregateType < Sequent::ApplicationRecord
      self.inheritance_column = nil
    end
  end
end
