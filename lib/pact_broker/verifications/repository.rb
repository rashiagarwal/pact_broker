require 'sequel'
require 'pact_broker/domain/verification'
require 'pact_broker/verifications/latest_verifications_by_consumer_version'
require 'pact_broker/verifications/all_verifications'
require 'pact_broker/verifications/sequence'

module PactBroker
  module Verifications
    class Repository

      include PactBroker::Repositories::Helpers
      include PactBroker::Repositories

      # Ideally this would just be a sequence, but Sqlite and MySQL don't support sequences
      # in the way we need to use them ie. determining what the next number will be before we
      # create the record, because Webmachine wants to set the URL of the resource that is about
      # to be created *before* we actually create it.
      def next_number
        Sequence.next_val
      end

      def create verification, provider_version_number, pact
        provider = pacticipant_repository.find_by_name(pact.provider_name)
        version = version_repository.find_by_pacticipant_id_and_number_or_create(provider.id, provider_version_number)
        verification.pact_version_id = pact_version_id_for(pact)
        verification.provider_version = version
        verification.save
        update_latest_verification_id(verification)
        verification
      end

      def update_latest_verification_id verification
        if PactBroker::Domain::Verification.db.table_exists?(:latest_verification_id_for_pact_version_and_provider_version)
          table = PactBroker::Domain::Verification.db[:latest_verification_id_for_pact_version_and_provider_version]
          if table.where(pact_version_id: verification.pact_version_id, provider_version_id: verification.provider_version_id).count == 0
            table.insert(pact_version_id: verification.pact_version_id, provider_version_id: verification.provider_version_id, provider_id: verification.provider_version.pacticipant_id, verification_id: verification.id)
          else
            table.where(pact_version_id: verification.pact_version_id, provider_version_id: verification.provider_version_id).update(verification_id: verification.id)
          end
        end
      end

      def find consumer_name, provider_name, pact_version_sha, verification_number
        PactBroker::Domain::Verification
          .select_all_qualified
          .join(:all_pact_publications, pact_version_id: :pact_version_id)
          .consumer(consumer_name)
          .provider(provider_name)
          .pact_version_sha(pact_version_sha)
          .verification_number(verification_number).single_record
      end

      def find_latest_verifications_for_consumer_version consumer_name, consumer_version_number
        # Use LatestPactPublicationsByConsumerVersion not AllPactPublcations because we don't
        # want verifications for shadowed revisions as it would be misleading.
        LatestVerificationsByConsumerVersion
          .select_all_qualified
          .join(:latest_pact_publications_by_consumer_versions, pact_version_id: :pact_version_id)
          .consumer(consumer_name)
          .consumer_version_number(consumer_version_number)
          .order(:provider_name)
          .all
      end

      # The most recent verification for the latest revision of the pact
      # belonging to the version with the largest consumer_version_order.

      def find_latest_verification_for consumer_name, provider_name, consumer_version_tag = nil
        query = LatestVerificationsByConsumerVersion
          .select_all_qualified
          .join(:all_pact_publications, pact_version_id: :pact_version_id)
          .consumer(consumer_name)
          .provider(provider_name)
        if consumer_version_tag == :untagged
          query = query.untagged
        elsif consumer_version_tag
          query = query.tag(consumer_version_tag)
        end
        query.reverse_order(
          Sequel[:all_pact_publications][:consumer_version_order],
          Sequel[:all_pact_publications][:revision_number],
          Sequel[LatestVerificationsByConsumerVersion.table_name][:number]
        ).limit(1).single_record
      end

      def find_latest_verification_for_tags consumer_name, provider_name, consumer_version_tag, provider_version_tag
        view_name = PactBroker::Verifications::AllVerifications.table_name
        query = PactBroker::Verifications::AllVerifications
          .select_all_qualified
          .join(:versions, {Sequel[:provider_versions][:id] => Sequel[view_name][:provider_version_id]}, {table_alias: :provider_versions})
          .join(:latest_pact_publications_by_consumer_versions, { Sequel[view_name][:pact_version_id] => Sequel[:latest_pact_publications_by_consumer_versions][:pact_version_id] })
          .consumer(consumer_name)
          .provider(provider_name)
          .tag(consumer_version_tag)
          .provider_version_tag(provider_version_tag)

        query.reverse_order(
          Sequel[:latest_pact_publications_by_consumer_versions][:consumer_version_order],
          Sequel[:latest_pact_publications_by_consumer_versions][:revision_number],
          Sequel[:provider_versions][:order],
          Sequel[view_name][:execution_date]
        ).limit(1).single_record
      end

      def pact_version_id_for pact
        PactBroker::Pacts::PactPublication.select(:pact_version_id).where(id: pact.id)
      end
    end
  end
end
