# frozen_string_literal: true

class Topic < Sequel::Model(:topics)
  one_to_many :messages
end
