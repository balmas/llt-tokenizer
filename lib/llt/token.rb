require 'llt/core/containable'
require 'llt/helpers/functions'

module LLT
  class Token
    include Containable

    require 'llt/token/word'
    require 'llt/token/punctuation'
    require 'llt/token/filler'

    include Helpers::Functions
    #include Phonology

    attr_reader :functions, :special_roles
    container_alias :forms

    def initialize(string)
      super
      @functions = set_functions
    end

    def special_roles
      @special_roles || []
    end

    def has_special_role?(role)
      special_roles.include?(role)
    end

    def set_special_role(*roles)
      @special_roles ||= []
      @special_roles += roles
    end

    # deprecated
    def add_form(form)
      @forms << form
    end

    # deprecated
    def add_forms(forms)
      @forms += forms
    end

    def use(*args)
      # hook method, overwritten by Word
    end
  end
end