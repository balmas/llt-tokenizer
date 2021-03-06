require 'array_scanner'
require 'llt/core'
require 'llt/constants/abbreviations'
require 'llt/core_extensions/array'
require 'llt/db_handler/prometheus'
require 'llt/helpers/metrical'

module LLT
  class Tokenizer
    require 'llt/token'
    require 'llt/tokenizer/worker'

    include Core::Serviceable
    include Constants::Abbreviations
    include Helpers::Metrical

    uses_db { DbHandler::Prometheus.new }

    attr_reader :default_options

    def self.default_options
      {
        shifting: true,
        enclitics_marker: '-',
        merging: true,
        indexing: true,
      }
    end

    def tokenize(text, add_to: nil, **options)
      raise ArgumentError.new("The argument passed must be a String") unless text.is_a?(String)
      return [] if text.empty?

      setup(text, options)

      find_abbreviations_and_join_strings
      split_enklitika_and_change_their_position
      merge_what_needs_merging if @merging # quam diu => quamdiu
      tokens = create_tokens

      add_to << tokens if add_to.respond_to?(:<<)
      tokens
    end

    def setup(text, options = {}, worker = [])
      @text   = text
      evaluate_metrical_presence(@text)
      @enclitics_marker = parse_option(:enclitics_marker, options)
      @merging          = parse_option(:merging, options)
      @shifting         = parse_option(:shifting, options)
      @indexing         = parse_option(:indexing, options)
      @worker = setup_worker(worker)
      @shift_range = shift_range(@shifting)
    end

    PUNCTUATION = /(([\.\?,!\-:"'”\(\)\[\]†]|<\/?.+?>|&(amp|quot|lt|gt|);)|(?<!&amp|quot|lt|gt|apos);)\1*/

    # This is here for two reasons:
    #   1) easier test setup, when a preliminary result shall be further evaluated
    #
    #   2) more importantly adding a level of indirection, when
    #      the given text holds metrical information. It adds a
    #      substitute implementation for the worker array, but only
    #      if it's needed - which should perform better, when there
    #      are no metrics involved (the default case)
    def setup_worker(worker)
      if worker.any?
        worker
      else
        elements = @text.gsub(PUNCTUATION, ' \0 ').split
        put_xml_attributes_back_together(elements)
        if metrical?
          Worker.new(elements, @enclitics_marker)
        else
          elements
        end
      end
    end

    def shift_range(shifting_enabled)
      shifting_enabled ? 0 : 1
    end

    def put_xml_attributes_back_together(elements)
      # elements could be like this
      # ['<tag', 'attr1="val"', 'attr1="val>']
      # and we want the complete xml tag back together
      as = ArrayScanner.new(elements)
      loop do
        last = as.look_behind
        if last && last.start_with?('<') &! last.end_with?('>')
          if as.current.match(/\w+=".*"$|>/)
            last << ' ' << as.current
            elements.delete_at(as.pos)
            # we don't need to forward, as we delete an element anyway
            next
          end
        else
          as.forward(1)
        end
        break if as.eoa?
      end
    end


  ######################

    # covers abbreviated Roman praenomen like Ti. in Ti. Claudius Nero
    # covers Roman date expression like a. d. V. Kal. Apr.
    ABBREVIATIONS = /^(#{ALL_ABBRS_PIPED})$/

    # %w{ Atque M . Cicero mittit } to %w{ Atque M. Cicero mittit }

    def find_abbreviations_and_join_strings
      arr = []
      @worker.each_with_index do |e, i|
        n = @worker[i + 1]
        if e =~ ABBREVIATIONS && n == "."
          @worker[i + 1] = n.prepend(e)
          arr << (i - arr.size)
        end
      end

      arr.each { |i| @worker.delete_at(i) }
    end

  ######################

    WORDS_ENDING_WITH_QUE = /^([qc]u[ei].*que|qu[ao]que|itaque|atque|ut[er].*que|utcumque|plerumque|denique|undique)$/i # neque taken out!
    WORDS_ENDING_WITH_NE  = /^(omne|sine|bene|paene)$/i
    WORDS_ENDING_WITH_VE  = /^(sive|neve)$/i

    # laetusque  to -que laetus
    # in eoque   to -que in eo
    # honestumne to -ne honestum
    #
    # but
    #
    # uterque, institutione, sive et al. remain

    ENCLITICS = %w{ que ne ve c }
    def split_enklitika_and_change_their_position
      split_with_force
      split_nec
      make_frequent_corrections
    end

    def split_with_force
      # uses brute force at first
      # the restrictor regexps handle only obvious cases

      # don't use c here atm
      ENCLITICS[0..-2].each do |encl|
        split_enklitikon(encl, self.class.const_get("WORDS_ENDING_WITH_#{encl.upcase}"))
      end
    end

    def split_enklitikon(encl, restrictors)
      # needs a word character in front - ne itself should be contained
      regexp = /(?<=\w)#{encl}$/

      indices = []
      @worker.each_with_index do |token, i|
        if token.match(regexp) && restrictors !~ token
          token.slice!(regexp)
          indices << (i + indices.size + @shift_range)
        end
      end

      indices.each { |i| @worker.insert(i, enclitic(encl)) }
    end

    def enclitic(val)
      "#{@enclitics_marker}#{val}"
    end

    def split_nec
      indices = []
      @worker.each_with_index do |token, i|
        if token == 'nec'
          token.slice!(-1)
          indices << (i + indices.size + @shift_range)
        end
      end

      indices.each { |i| @worker.insert(i, enclitic('c')) }
    end

    def make_frequent_corrections
      # uses db lookups
      # # TODO 27.11.13 14:15 by LFDM
      # Implement caching here
      ne_corrections
      que_corrections
      ve_corrections
    end

    def que_corrections
      # this is used in rare only in cases like in eoque
      # which needs a shift to -que in eo
      if @shifting
        to_be_shifted_que_indices.each do |i|
          @worker.insert(i - 1, @worker.delete_at(i))
        end
      end
    end

    def to_be_shifted_que_indices
      # double shifts would properly fail, but they  might never happen
      @worker.each_with_index.each_with_object([]) do |(element, index), accumulator|
        accumulator << index if is_que?(element) && led_by_preposition?(index)
      end
    end

    def is_que?(element)
      element == enclitic('que')
    end

    def led_by_preposition?(index)
      @worker[index - 1] =~ /^(in|ad|ob)$/i # and others
    end

    def ne_corrections
      corrections = []
      @worker.each_with_index do |w, i|
        if w == enclitic('ne')
          orig_el = original_word(i)

          entries = []
          entries += lookup(orig_el, :noun, :nom)           if orig_el =~ /io$/   # actio-ne ratio-ne
          entries += lookup(orig_el + "n", :persona, :stem) if orig_el =~ /o$/    # Plato-ne Cicero-ne Solo-ne
          entries += lookup(orig_el + "n", :noun, :stem)    if orig_el =~ /d?i$/  # fortitudi-ne ratio-ne libidi-ne homi-ne
          entries += lookup(orig_el + "n", :noun, :stem)    if orig_el =~ /mi$/   # flumi-ne agmi-ne
          entries += lookup(orig_el + "n", :adjective, :stem)                     # communis commune

          if entries.any?(&:third_decl_with_possible_ne_abl?)
            corrections << i - corrections.size
          end
        end
      end

      reverse_splittings(corrections)
    end

    def ve_corrections
      corrections = []
      @worker.each_with_index do |w, i|
        if w == enclitic('ve')
          orig_el = original_word(i)

          entries = []
          entries += lookup(orig_el + 'v',  :adjective, :stem, 1)
          entries += lookup(orig_el + 'v',  :adjective, :stem, 3)
          entries += lookup(orig_el + 'v',  :noun,      :stem, [2, 5])
          entries += lookup(orig_el + 've', :verb,      :pr,   2)
          entries += lookup(orig_el + 'v',  :verb,      :pr,   [3, 5]) # not sure if such a word of 5 exists


          if entries.any?
            corrections << i - corrections.size
          end
        end
      end

      reverse_splittings(corrections)
    end

    def original_word(i)
      # there are two possible scenarios at this point
      # with shifting enabled:
      #         i  i + 1
      #   arma que virum
      # with shifting disabled:
      #        i - 1  i
      #   arma virum que
      @worker[i + (@shifting ? 1 : -1)]
    end

    def lookup(string, type, column, inflection_class = 3)
      string = (type == :persona ? string : string.downcase)
      query = {
                type: type, stem_type: column, stem: string,
                restrictions: { type: :inflection_class, values: Array(inflection_class) }
              }
      @db.look_up_stem(query)
    end

    def reverse_splittings(indices)
      indices.each do |i|
        # need to retrieve the orig word before the splitted var is
        # assigned, as it deletes something in the worker
        ow = original_word(i)
        splitted  = @worker.delete_at(i).delete(@enclitics_marker)
        ow << splitted
      end
    end


  ######################

    MERGE_WORDS = [ %w{ quam diu }, ['non', /null.{1,4}$/] ]

    # quam diu to quamdiu
    def merge_what_needs_merging
      to_delete = []
      @worker.each_overlapping_pair.each_with_index do |pair, i|
        merge_words(pair, i, to_delete) if is_a_mergable_pair?(*pair)
      end
      to_delete.each { |i| @worker.delete_at(i) }
    end

    def is_a_mergable_pair?(x, y)
      # x, i.e. quam in quamdiu, needs to be downcased, as it could be in a
      # sentence's first position
      MERGE_WORDS.any? { |a, b| a === x.downcase && b === y  }
    end

    def merge_words(pair, i, to_delete)
      pair.first << pair.last
      to_delete  << (i + 1 - to_delete.size)
    end

  ######################

    ABBR_NAME_WITH_DOT       = /^(#{NAMES_PIPED})\.$/
    ROMAN_DATE_EXPR_WITH_DOT = /^(#{DATES_PIPED})\.$/
    PUNCT_ITSELF             = Regexp.new(PUNCTUATION.source + '$')
    XML_TAG                  = /<\/?.+?>/

    def create_tokens
      # call #to_a is to retrieve (and align) optional metrical data
      reset_id
      @worker.to_a.map! do |el|
        case el
        when XML_TAG                  then Token::XmlTag.new(el)
        when ABBR_NAME_WITH_DOT       then raise_id and Token::Filler.new(el, @id)
        when ROMAN_DATE_EXPR_WITH_DOT then raise_id and Token::Filler.new(el, @id)
        when PUNCT_ITSELF             then raise_id and Token::Punctuation.new(el, @id)
        else                               raise_id and Token::Word.new(el, @id)
        end
      end
    end

    def reset_id
      @id = (@indexing ? @id = 0 : nil)
    end

    def raise_id
      if @indexing
        @id += 1
      else
        # need to return true because this is used as first part
        # of an and construction
        true
      end
    end

    def preliminary
      @worker.to_a
    end
  end
end
