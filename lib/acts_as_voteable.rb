module ThumbsUp
  module ActsAsVoteable #:nodoc:

    def self.included(base)
      base.extend ThumbsUp::Base
      base.extend ClassMethods
    end

    module ClassMethods
      def acts_as_voteable
        has_many ThumbsUp.configuration[:voteable_relationship_name],
                 :as => :voteable,
                 :dependent => :destroy,
                 :class_name => 'Vote'

        include ThumbsUp::ActsAsVoteable::InstanceMethods
        extend  ThumbsUp::ActsAsVoteable::SingletonMethods
      end
    end

    module SingletonMethods

      # Calculate the plusminus for a group of voteables in one database query.
      # This returns an Arel relation, so you can add conditions as you like chained on to
      # this method call.
      # i.e. Posts.tally.where('votes.created_at > ?', 2.days.ago)
      # You can also have the upvotes and downvotes returned separately in the same query:
      # Post.plusminus_tally(:separate_updown => true)
      def plusminus_tally(params = {})
        t = self.joins("LEFT OUTER JOIN #{Vote.table_name} ON #{self.table_name}.id = #{Vote.table_name}.voteable_id AND #{Vote.table_name}.voteable_type = '#{self.name}'")
        t = t.order("plusminus_tally DESC")
        t = t.group(column_names_for_tally)
        t = t.select("#{self.table_name}.*")
        t = t.select("SUM(CASE #{Vote.table_name}.vote WHEN #{quoted_true} THEN 1 WHEN #{quoted_false} THEN -1 ELSE 0 END) AS plusminus_tally")
        if params[:separate_updown]
          t = t.select("SUM(CASE #{Vote.table_name}.vote WHEN #{quoted_true} THEN 1 WHEN #{quoted_false} THEN 0 ELSE 0 END) AS up")
          t = t.select("SUM(CASE #{Vote.table_name}.vote WHEN #{quoted_true} THEN 0 WHEN #{quoted_false} THEN 1 ELSE 0 END) AS down")
        end
        t = t.select("COUNT(#{Vote.table_name}.id) AS vote_count")
      end

      # #rank_tally is depreciated.
      alias_method :rank_tally, :plusminus_tally

      # Calculate the vote counts for all voteables of my type.
      # This method returns all voteables (even without any votes) by default.
      # The vote count for each voteable is available as #vote_count.
      # This returns an Arel relation, so you can add conditions as you like chained on to
      # this method call.
      # i.e. Posts.tally.where('votes.created_at > ?', 2.days.ago)
      def tally(*args)
        t = self.joins("LEFT OUTER JOIN #{Vote.table_name} ON #{self.table_name}.id = #{Vote.table_name}.voteable_id")
        t = t.order("vote_count DESC")
        t = t.group(column_names_for_tally)
        t = t.select("#{self.table_name}.*")
        t = t.select("COUNT(#{Vote.table_name}.id) AS vote_count")
      end

      def column_names_for_tally
        column_names.map { |column| "#{self.table_name}.#{column}" }.join(', ')
      end

    end

    module InstanceMethods

      # wraps the dynamic, configured, relationship name
      def _votes_by(tag = nil)
        scope = self.send(ThumbsUp.configuration[:voteable_relationship_name])
        tag ? scope.where(voteable_tag: tag) : scope
      end

      def votes_for(tag = nil)
        self._votes_by(tag).where(:vote => true).count
      end

      def votes_against(tag = nil)
        self._votes_by(tag).where(:vote => false).count
      end

      def percent_for(tag = nil)
        (votes_for(tag).to_f * 100 / (self._votes_by(tag).size + 0.0001)).round
      end

      def percent_against(tag = nil)
        (votes_against(tag).to_f * 100 / (self._votes_by(tag).size + 0.0001)).round
      end

      # You'll probably want to use this method to display how 'good' a particular voteable
      # is, and/or sort based on it.
      # If you're using this for a lot of voteables, then you'd best use the #plusminus_tally
      # method above.
      # plusminus_tally doesn't work with tag
      def plusminus(tag = nil)
        if tag
          votes_for(tag) - votes_against(tag)
        else
          respond_to?(:plusminus_tally) ? plusminus_tally : (votes_for - votes_against)
        end
      end

      # The lower bound of a Wilson Score with a default confidence interval of 95%. Gives a more accurate representation of average rating (plusminus) based on the number of positive ratings and total ratings.
      # http://evanmiller.org/how-not-to-sort-by-average-rating.html
      #def ci_plusminus(confidence = 0.95)
      #  require 'statistics2'
      #  n = votes.size
      #  if n == 0
      #    return 0
      #  end
      #  z = Statistics2.pnormaldist(1 - (1 - confidence) / 2)
      #  phat = 1.0 * votes_for / n
      #  (phat + z * z / (2 * n) - z * Math.sqrt((phat * (1 - phat) + z * z / (4 * n)) / n)) / (1 + z * z / n)
      #end


      # ci_plusminus(confidence: 0.95, tag: 'test_tag')
      def ci_plusminus(options ={})
        confidence = options[:confidence] ? options[:confidence] : 0.95
        tag = options[:tag] ? options[:tag] : nil
        require 'statistics2'
        n = (tag ? votes.where(voteable_tag: tag) : votes ).size
        return 0 if n == 0
        z = Statistics2.pnormaldist(1 - (1 - confidence) / 2)
        phat = 1.0 * votes_for(tag) / n
        (phat + z * z / (2 * n) - z * Math.sqrt((phat * (1 - phat) + z * z / (4 * n)) / n)) / (1 + z * z / n)
      end

      def votes_count(tag = nil)
        (tag ? votes.where(voteable_tag: tag) : votes).size
      end

      def voters_who_voted(tag = nil)
        (tag ? votes.where(voteable_tag: tag) : votes).map(&:voter).uniq
      end

      def voters_who_voted_for(tag = nil)
        args = {vote: true}
        args.merge!({voteable_tag: tag}) if tag
        votes.where(args).map(&:voter).uniq
      end

      def voters_who_voted_against(tag = nil)
        args = {vote: false}
        args.merge!({voteable_tag: tag}) if tag
        votes.where(args).map(&:voter).uniq
      end

      def voted_by?(voter, tag = nil)
        args = {voteable_id: self.id, voteable_type: self.class.base_class.name, voter_id: voter.id}
        args.merge!({voteable_tag: tag}) if tag
        0 < Vote.where(args).count
      end

    end
  end
end
