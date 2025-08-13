# Sanitizes tag names so they comply with Git refname rules
# Includes explicit rename mappings, then a generic normalizer.
module Svn2Git
    module RefnameSanitize
      # Explicit rename map: raw SVN tag name -> desired Git tag name
      # Left-hand keys must match exactly what git-svn exposes under refs/remotes/svn/tags/*
      EXPLICIT = {
        "Version 2.7.1 using updated Peter's Data Entry Suite" => "v2.7.1-peters-data-entry-suite",
        "Version 2.7.1" => "Version_2.7.1",
        "Version 3.0.13 First C# Release" => "Version_3.0.13_First_Csharp_Release",
        "Version 2.8.0 Last VB Release" => "Version_2.8.0_Last_VB_Release",
        "Version 3.0.14 Release, Manual Accruals Fix" => "Version_3.0.14_Release_Manual_Accruals_Fix",
      }.freeze
  
      # Characters Git forbids inside refnames
      FORBIDDEN = /[\x00-\x1F\x7F ~^:?*\[\\]/.freeze
  
      def self.tag(raw, used = nil)
        # If exact mapping exists, return it
        mapped = EXPLICIT[raw]
        return dedupe(mapped, used) if mapped
  
        # Otherwise normalize generically to be safe and readable
        s = raw.dup
  
        # Replace C# with Csharp
        s.gsub!(/C#/, "Csharp")
  
        # Remove apostrophes, commas
        s.tr!("'", "")
        s.tr!(",", "")
  
        # Spaces to underscores
        s.gsub!(/\s+/, "_")
  
        # Replace forbidden characters with underscore
        s.gsub!(FORBIDDEN, "_")
  
        # Replace "@{" sequence
        s.gsub!(/@\{/, "_")
  
        # Trim leading/trailing slashes or dots
        s.gsub!(%r{\A[./]+}, "")
        s.gsub!(%r{[./]+\z}, "")
  
        # Disallow ending in ".lock"
        s.sub!(/\.lock\z/, "")
  
        # Ensure not empty
        s = "tag" if s.empty?
  
        # Avoid pure 40-hex
        s = "tag-#{s}" if s.match?(/\A[0-9a-fA-F]{40}\z/)
  
        dedupe(s, used)
      end
  
      def self.dedupe(name, used)
        return name unless used
        base = name
        i = 2
        while used.include?(name)
          name = "#{base}-#{i}"
          i += 1
        end
        used << name
        name
      end
    end
  end
  