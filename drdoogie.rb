require 'rubygems'
require 'bundler/setup'
require 'yaml'
require 'pry'

Bundler.require

# If there are problems, this is the most time we'll wait (in seconds).
MAX_BACKOFF = 12.8

@config_path = __FILE__.sub(/\.rb$/, '.yml')

unless File.exist? @config_path
  puts "Unable to find: #{@config_path}"
  exit
end

@config = YAML.load_file(@config_path)

@options = {
  chain: @config[:chain_options][:chain].to_sym,
  url: @config[:chain_options][:url],
  logger: Logger.new(__FILE__.sub(/\.rb$/, '.log'))
}

def may_vote?(op)
  @config[:trails].keys.map(&:to_s).include? op.voter
end

def vote(trailing_vote, comment)
  age = (Time.now - Time.parse(comment.created + 'Z')).to_i / 60
  reply = comment.parent_author != ''
  tags = JSON[comment.json_metadata]['tags']
  upvote = trailing_vote.weight > 0
  downvote = trailing_vote.weight < 0
  unvote = trailing_vote.weight == 0
  
  @config[:trails].each do |trail, options|
    next unless age <= options[:max_age]
    next if reply && !options[:enable_comments]
    next if upvote && !options[:allow_upvote]
    next if downvote && !options[:allow_downvote]
    next if (options[:skip_tags] & tags).any?
    next if !!options[:only_tags] && (options[:only_tags] & tags).any?
    
    puts "#{trailing_vote.voter} voted for #{trailing_vote.author}/#{trailing_vote.permlink} at #{trailing_vote.weight / 100.0} %"
    
    scale = options[:scale_votes].to_f / 100
    weight = (trailing_vote.weight * scale).to_i
    
    @config[:voters].each do |voter|
      name, wif = voter.split(' ')
      next if comment.active_votes.map(&:voter).include? name
      
      op = {
        type: :vote,
        voter: name,
        author: trailing_vote.author,
        permlink: trailing_vote.permlink,
        weight: weight
      }
      
      tx = Radiator::Transaction.new(@options.dup.merge(wif: wif))
      tx.operations << op
      puts tx.process(true)
    end
  end
end

puts "Now trailing #{@config[:trails].keys.join(', ')} ..."

loop do
  @api = Radiator::Api.new(@options.dup)
  @stream = Radiator::Stream.new(@options.dup)
  
  mode = @config[:global][:mode].to_sym rescue :irreversible
  
  begin
    @stream.operations(:vote, nil, mode) do |op|
      @backoff ||= 0.001
      next unless may_vote?(op)
      response = @api.get_content(op.author, op.permlink)
      comment = response.result
      
      Thread.new do
        vote(op, comment)
      end
      
      @backoff = nil
    end
  rescue => e
    m = e.message
    
    if m =~ /undefined method `transactions' for nil:NilClass/ && mode == :head
      # Block hasn't reached the node yet.  Just retry with a small delay
      # without reporting an error.
      
      sleep 0.2
    else
      puts "Pausing #{@backoff} :: Unable to stream on current node.  Error: #{e}"
      
      sleep @backoff
      @backoff = [@backoff * 2, MAX_BACKOFF].min
    end
  end
end
