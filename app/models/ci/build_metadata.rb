# frozen_string_literal: true

module Ci
  # The purpose of this class is to store Build related data that can be disposed.
  # Data that should be persisted forever, should be stored with Ci::Build model.
  class BuildMetadata < Ci::ApplicationRecord
    BuildTimeout = Struct.new(:value, :source)

    include Ci::Partitionable
    include Presentable
    include ChronicDurationAttribute
    include Gitlab::Utils::StrongMemoize

    self.table_name = 'p_ci_builds_metadata'
    self.primary_key = 'id'

    query_constraints :id, :partition_id
    partitionable scope: :build, partitioned: true

    belongs_to :build, # rubocop: disable Rails/InverseOf -- this relation is not present on CommitStatus
      ->(metadata) { in_partition(metadata) },
      partition_foreign_key: :partition_id,
      class_name: 'CommitStatus'

    belongs_to :project

    before_create :set_build_project

    validates :build, presence: true
    validates :id_tokens, json_schema: { filename: 'build_metadata_id_tokens' }
    validates :secrets, json_schema: { filename: 'build_metadata_secrets' }

    attribute :config_options, :sym_jsonb
    attribute :config_variables, :sym_jsonb
    attribute :runtime_runner_features, :sym_jsonb

    chronic_duration_attr_reader :timeout_human_readable, :timeout

    scope :scoped_build, -> do
      where(arel_table[:build_id].eq(Ci::Build.arel_table[:id]))
      .where(arel_table[:partition_id].eq(Ci::Build.arel_table[:partition_id]))
    end

    scope :with_interruptible, -> { where(interruptible: true) }
    scope :with_exposed_artifacts, -> { where(has_exposed_artifacts: true) }

    enum timeout_source: {
      unknown_timeout_source: 1,
      project_timeout_source: 2,
      runner_timeout_source: 3,
      job_timeout_source: 4
    }

    def update_timeout_state
      timeout = timeout_with_highest_precedence

      return unless timeout

      update(timeout: timeout.value, timeout_source: timeout.source)
    end

    def set_cancel_gracefully
      runtime_runner_features[:cancel_gracefully] = true
    end

    def cancel_gracefully?
      runtime_runner_features[:cancel_gracefully] == true
    end

    def enable_debug_trace!
      self.debug_trace_enabled = true
      save! if changes.any?
      true
    end

    def manual_confirmation_message
      return unless config_options && config_options[:manual_confirmation]

      variables = config_variables_to_hash
      config_options[:manual_confirmation].gsub(/\$[A-Za-z]\w*/) do |match|
        name = match.delete_prefix('$')
        value = variables[name]
        next match unless value

        "$#{name}=#{value}"
      end
    end

    private

    def set_build_project
      self.project_id ||= build.project_id
    end

    def timeout_with_highest_precedence
      [(job_timeout || project_timeout), runner_timeout].compact.min_by(&:value)
    end

    def project_timeout
      strong_memoize(:project_timeout) do
        BuildTimeout.new(project&.build_timeout, :project_timeout_source)
      end
    end

    def job_timeout
      return unless build.options

      strong_memoize(:job_timeout) do
        if timeout_from_options = build.options[:job_timeout]
          BuildTimeout.new(timeout_from_options, :job_timeout_source)
        end
      end
    end

    def runner_timeout
      return unless runner_timeout_set?

      strong_memoize(:runner_timeout) do
        BuildTimeout.new(build.runner.maximum_timeout, :runner_timeout_source)
      end
    end

    def runner_timeout_set?
      build.runner&.maximum_timeout.to_i > 0
    end

    def config_variables_to_hash
      config_variables.each_with_object({}) do |item, hash|
        hash[item[:key]] = item[:value]
        hash
      end
    end
  end
end
