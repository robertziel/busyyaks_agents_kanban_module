# frozen_string_literal: true

require "digest"
require "json"

module AgentsKanban
  # A content revision: a short digest of exactly the JSON a client renders. Clients poll it and refetch only
  # when it changes — nothing (a label recolour, a reorder in the same second) can change without changing it.
  module Rev
    module_function

    def of(obj) = Digest::SHA1.hexdigest(JSON.generate(obj))[0, 16]
  end
end
