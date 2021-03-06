class Shows
	@@shows_cache_path = File.join(File.dirname(__FILE__), *%w[../cache/shows])
	@@website = "sw.daerhtesaeler".reverse # don't attract search engines!
	@@sm_url = "http://"+@@website+("lmx.1trap_tsop/".reverse) # sitemap url
	@@debug = false
	
	def self.run(to_download, already_downloaded, max)
		result = []
		remaining = max
		shows = to_download.list.collect {
			|name|
			name.downcase.gsub(" ", "-").gsub("'", "").gsub(/\(|\)/, "")
		}
		
		already_downloaded = already_downloaded.collect {
			|item|
			[item, item.scan(/(.*?s\d\de\d\d(e\d\d)?)-/)]
		}.flatten.compact
				
		shows_cache = ListFile.new(@@shows_cache_path)

		sitemap = Helper.open_uri(@@sm_url, 153600).to_s # limit fetch size to 150KB — more than enough, better than fetching a 1MB page
		sitemap = sitemap.scan(/.*>/im).first
		releases = sitemap.scan(/<loc>(http\:\/\/#{@@website.gsub(".", "\\.")}\/tv\-shows\/(.*?)\/)<\/loc>.*?<lastmod>(.*?)<\/lastmod>/im).uniq.take(50)
		
		releases.each {
			|url, release_name, lastmod|
			
			release_name = release_name.gsub(/\s/m, "")
			puts "Trying #{release_name}..." if @@debug
			
			begin
				# Can't use parse().to_time in Ruby < 1.9
				fallback = ((Time.now.to_i - DateTime.parse(lastmod).strftime("%s").to_i) > 3600*2)
				puts "Fallback: #{fallback} (diff: #{(Time.now.to_i - DateTime.parse(lastmod).strftime("%s").to_i)})" if @@debug
			rescue
				# couldn't parse date because it's incomplete
				# happens sometimes because we chose to limit fetch size to 150KB (line 22~)
				next 
			end

			# Checking to see if it's already downloaded
			episode_number = release_name.scan(/(.*?s\d\de\d\d(\-?e\d\d)?)-/).flatten
			episode_number = (episode_number.empty? ? nil : episode_number.first)
			
			if already_downloaded.include?(release_name)
				puts "Already downloaded." if @@debug
			elsif already_downloaded.include?(episode_number)
				puts "Episode already downloaded." if @@debug
			elsif shows_cache.include?(release_name)
				puts "Released before first-time setup, won't check." if @@debug
			else
				shows.each {
					|show|
					is_season_pack = !(release_name =~ Regexp.new("^"+show+"-s\\d\\d([^e]|$)", true)).nil?
					if (release_name.start_with?(show) && !is_season_pack)
						begin
							page = (open url).read.to_s
							
							release_names = self.check_page_for_release_names(page, show.gsub("-", "."), release_name)
							links = self.check_page_for_relevant_links(page, release_names, release_name, fallback)
							
							if (!links.nil?)
								result << links
								remaining = remaining - 1
							end
							
							break
						rescue StandardError => e
							puts e.backtrace.first
							puts e.to_s
						end
					end
				}
			end

			break if remaining < 1
		}
		
		return result
	end
	
	def self.always_run
	end
	
	def self.install
		sitemap = Helper.open_uri(@@sm_url, 153600).to_s
		releases = sitemap.scan(/<loc>http\:\/\/#{@@website.gsub(".", "\\.")}\/tv\-shows\/(.*?)\/<\/loc>/im).flatten.uniq.take(50)
		
		ListFile.overwrite(@@shows_cache_path, releases)
	end
	
	def self.check_page_for_relevant_links(source, release_names, page_name, fallback)
		source = source.scan(/<div\sclass=\"postarea\">(.*?)<div\sclass=\"clear\"/im).flatten
		source = source.first.gsub(/\n/, "").gsub(/<br\s?\/?>/, "").strip
		parts = source.split(/<hr\s*?\/?>/im)
		
		parts = parts[1..-1]
		
		wanted_release = nil
		release_names.each_index {
			|i|
			wanted_release = release_names[i] if release_names[i].include?("720p")
		}
		
		if (wanted_release.nil?)
			if (!fallback)
				puts "720p version still not uploaded... will check later..." if @@debug
				return nil
			else
				puts "Couldn't find 720p version, falling back to anything else..." if @@debug
				wanted_release = release_names.last
			end
		end
		
		relevant_part = parts[release_names.index(wanted_release)]
		if (!relevant_part || !relevant_part.include?(wanted_release))
			parts.each {
				|part|
				relevant_part = part if part.include?(wanted_release)
			}
		end
		
		groups = catch(:groups) {
			links = LinkScanner.scan_for_pl_links(relevant_part)
			groups = LinkScanner.get(links)
			throw(:groups, groups) unless links.empty? || groups.first[:dead]
			
			links = LinkScanner.scan_for_bu_links(relevant_part)
			groups = LinkScanner.get(links)
			throw(:groups, groups) unless links.empty?
			
			links = LinkScanner.scan_for_gf_links(relevant_part)
			groups = LinkScanner.get(links)
			throw(:groups, groups) unless links.empty? || groups.first[:dead]
			
			throw(:groups)
		}

		raise StandardError.new("No valid links found.") if groups.nil? || groups.empty?
		
		best_group = groups.first
		groups.each {
			|group|
			best_group = group if group[:size] > best_group[:size]
		}
		
		{
			:files => best_group[:files],
			:name => wanted_release,
			:reference => page_name,
			:host => best_group[:host]
		}
	end
	
	def self.check_page_for_release_names(source, show_looking_for, expected_release)
		source = source.scan(/<div\sclass=\"postarea\">(.*?)<div\sclass=\"clear\"/im).flatten

		raise StandardError.new("Couldn't find release info") if source.empty?
		
		# US release naming convention: show.name.S01E01
		us_regex = Regexp.new(show_looking_for.gsub(/\./, "[\\.\\s]")+"[\\.\\s]S\\d\\dE\\d\\d.*", true)
		# UK release naming convention: show_name.1x01
		uk_regex = Regexp.new(show_looking_for.gsub(/\./, "[_\\s]")+"[\\.\\s]\\d\\d?.{1,2}\\d\\d.*", true)
		# Other release naming conventions, e.g. show.name.yyyy.mm.dd
		other_regex =  Regexp.new("^"+show_looking_for.gsub(/\./, "[\\.\\s]")+"[\\.\\s].*", true)
		
		source = source.first.gsub(/\n/, "").gsub(/<br\s?\/?>/, "").strip
		bolded_parts = source.scan(/<strong>(.*?)<\/strong>/).flatten
		release_names = []
		
		bolded_parts.each {
			|part|

			part = part.strip
			release_names << part.scan(us_regex)
			release_names << part.scan(uk_regex)
			release_names << part.scan(other_regex)
		}
		
		release_names = release_names.flatten.uniq.compact
		
		raise StandardError.new("No releases are uploaded yet for #{expected_release}...") if release_names.empty?
		
		release_names
	end
	
	def self.on_demand(reference = nil)
		result = []
		
		if (reference.nil?)
			sitemap = (open @@sm_url).read.to_s
			releases = sitemap.scan(/<loc>(http\:\/\/#{@@website.gsub(".", "\\.")}\/tv\-shows\/(.*?)\/)<\/loc>.*?<lastmod>(.*?)<\/lastmod>/im).take(200)
			
			releases.each {
				|url, release_name, lastmod|
				
				formatted_name = release_name.gsub(/-|_|\./, " ")
	
				parts = formatted_name.split(" ").compact
				
				parts = parts.collect {
					|word|
					word = word.capitalize unless ["and", "of", "with", "in", "x264"].include?(word)
					word = word.upcase if ["au", "us", "uk", "ca", "hdtv", "xvid", "pdtv", "web", "dl"].include?(word.downcase)
					word = word.upcase if word =~ /s\d\de\d\d/i
					word
				}
				
				parts << parts.pop.upcase unless parts.empty?
				
				formatted_name = parts.join(" ")
				
				result << [formatted_name, release_name]
			}
		else
			source = (open "http://#{@@website}/tv-shows/#{CGI.escape(reference)}").read.to_s
			result = LinkScanner.threaded_scan_and_get(source, {:reference => reference})
		end
		
		result
	end
	
	def self.settings_notice
		"Type one show name per line.
		
		<b>Example:</b>
		Breaking Bad
		The Big Bang Theory
		The Walking Dead
		Two and a Half Men"
	end
	
	def self.list_sources
		["pogdesign", "rottentomatoes_boxoffice", "rottentomatoes_upcomingdvd", "rottentomatoes_upcomingmovies"]
	end
	
	def self.has_on_demand?
		true
	end
	
	def self.description
		"Downloads US & UK TV shows from <a href=\"http://#{@@website}\">#{@@website}</a> via direct links (PutLocker/BillionUploads/GameFront). Has most airing shows."
	end
	
	def self.broken?
		false
	end
	
	def self.best_group(file_groups)
		groups = file_groups.compact.collect {
			|group|
			group unless group[:dead]
		}.compact.sort {
			|group_a, group_b|
			
			size_a = group_a.nil? ? 0 : group_a[:size]
			size_b = group_b.nil? ? 0 : group_b[:size]
			
			if (size_b == 0 || size_a == 0)
				size_b <=> size_a
			else
				a_is_putlocker = group_a[:files].first[:url].downcase.include?("putlocker.com") ? true : false
				b_is_putlocker = group_b[:files].first[:url].downcase.include?("putlocker.com") ? true : false
				
				if (a_is_putlocker != b_is_putlocker)
					a_is_putlocker ? size_b <=> size_a+5242880 : size_b+5242880 <=> size_a
				else
					size_b <=> size_a
				end
			end
		}
		
		groups.first
	end
end