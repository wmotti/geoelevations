require 'json'
require 'open-uri'

require_relative 'utils'

module GeoElevation

    SRTM_BASE_URL = 'https://dds.cr.usgs.gov/srtm'
    SRTM1_URL     = '/version2_1/SRTM1/'
    SRTM3_URL     = '/version2_1/SRTM3/'
    DIR_NAME      = "#{Dir.home}/.elevations.rb"
    DEFAULT_TIMEOUT = 15

    EGM2008_URL   = 'http://earth-info.nga.mil/GandG/wgs84/gravitymod/egm2008/Small_Endian/Und_min1x1_egm2008_isw=82_WGS84_TideFree_SE.gz'
    # Test:
    #EGM2008_URL   = 'http://localhost/Und_min2.5x2.5_egm2008_isw=82_WGS84_TideFree_SE.gz'

    class Srtm
        def initialize(srtm_dir=DIR_NAME, timeout: DEFAULT_TIMEOUT)
            # Just in case...
            @dir_name = srtm_dir
            json = Retriever::prepare_folder srtm_dir
            # Dictionary with all files and urls (as is saved in ~/.elevations.rb/list.json)
            @files = JSON.load(json)
            @cached_srtm_files = {}
            @timeout = timeout
        end

        # If approximate is True then only the points from SRTM grid will be
        # used, otherwise a basic aproximation of nearby points will be calculated.
        def get_elevation(latitude, longitude, approximate=false)
            if approximate
                get_approximation(latitude, longitude)
            else
                srtm_file = get_file(latitude, longitude)
                srtm_file.get_elevation(latitude, longitude)
            end
        end

        def get_approximation(latitude, longitude)
            srtm_file = get_file(latitude, longitude)
            return nil if srtm_file.nil?

            # TODO(MG) manage discrepancies between SRTM1 and SRTM3
            # ATM this will be more inaccurate at the seams
            d = 1.0 / (srtm_file.square_side - 1)

            # Since the less the distance => the more important should be the
            # distance of the point, we'll use d-distance as importance coef
            # here:
            lat_d = (latitude / d) % 1
            lon_d = (longitude / d) % 1

            elevation_1 = get_elevation(latitude, longitude, false)
            elevation_2 = get_elevation(latitude + d, longitude, false)
            elevation_3 = get_elevation(latitude, longitude + d, false)
            elevation_4 = get_elevation(latitude + d, longitude + d, false)

            if elevation_1.nil? || elevation_2.nil? || elevation_3.nil? || elevation_4.nil?
                elevation = self.get_elevation(latitude, longitude, false)
                return nil if elevation.nil?
                elevation_1 ||= elevation
                elevation_2 ||= elevation
                elevation_3 ||= elevation
                elevation_4 ||= elevation
            end

            return (1. - lat_d) * (1. - lon_d) * elevation_1 +
              lat_d * (1. - lon_d) * elevation_2 +
              (1. - lat_d) * lon_d * elevation_3 +
              lat_d * lon_d * elevation_4
        end

        def get_file(latitude, longitude)
            file_name = get_file_name(latitude, longitude)

            if @cached_srtm_files.has_key?(file_name)
                return @cached_srtm_files[file_name]
            end

            file, url = find_file_name_and_url(file_name, 'srtm1')
            if ! file && ! url
                file, url = find_file_name_and_url(file_name, 'srtm3')
            end
            if ! file && ! url
                @cached_srtm_files[file_name] = nil
                return nil
            end

            file_name = file.sub('.zip', '')
            local_file_name = File.join(@dir_name, file_name)
            if ! File.exist?(local_file_name)
                puts "Retrieving #{file_name} because #{local_file_name} not found"
                file_contents = open(url, read_timeout: @timeout, open_timeout: @timeout).read
                file_contents = GeoElevation::Utils::unzip(file_contents, file_name)
                open(local_file_name, 'wb').write(file_contents)
            end

            file = GeoElevation::SrtmFile.new(local_file_name)

            @cached_srtm_files[file_name] = file

            file
        end

        def find_file_name_and_url(file_name, srtm_version)
            for candidate_file_name in @files[srtm_version].keys
                if candidate_file_name.index(file_name) == 0
                    return [candidate_file_name, "#{GeoElevation::SRTM_BASE_URL}#{@files[srtm_version][candidate_file_name]}"]
                end
            end

            nil
        end

        #
        # Return the file name no matter if the actual SRTM file exists.
        #
        def get_file_name(latitude, longitude)
            north_south = latitude >= 0 ? 'N' : 'S'
            east_west = longitude >= 0 ? 'E' : 'W'

            lat = latitude.floor.to_i.abs.to_s.rjust(2, '0')
            lon = longitude.floor.to_i.abs.to_s.rjust(3, '0')

            "#{north_south}#{lat}#{east_west}#{lon}.hgt"
        end
    end

    class SrtmFile
        def initialize(local_file_name)
            @local_file_name = local_file_name
            @file = open(@local_file_name)
            size = File.size?(@local_file_name)
            @square_side = Math.sqrt(size / 2)

            if @square_side != @square_side.to_i
                raise "Invalid file size #{size}"
            end

            parse_file_name_starting_position()
        end

        # Returns (latitude, longitude) of lower left point of the file
        def parse_file_name_starting_position()
            groups = @local_file_name.scan(/([NS])(\d+)([EW])(\d+)\.hgt/)[0]

            if groups.length != 4
                raise "Invalid file name #{@file_name}"
            end

            @latitude = groups[1].to_i * (groups[0] == 'N' ? 1 : -1)
            @longitude = groups[3].to_i * (groups[2] == 'E' ? 1 : -1)
        end

        def get_row_and_column(latitude, longitude)
            if latitude == nil || longitude == nil
                return nil
            end

            [ ((@latitude + 1 - latitude) * (@square_side - 1).to_f).floor, ((longitude - @longitude) * (@square_side - 1).to_f).floor ]
        end

        def get_elevation(latitude, longitude)
            if ! (@latitude <= latitude && latitude < @latitude + 1)
                raise "Invalid latitude #{latitude} for file #{@file_name}"
            end
            if ! (@longitude <= longitude && longitude < @longitude + 1)
                raise "Invalid longitude #{longitude} for file #{@file_name}"
            end

            row, column = get_row_and_column(latitude, longitude)
            get_elevation_from_row_and_column(row.to_i, column.to_i)
        end


        def get_elevation_from_row_and_column(row, column)
            i = row * (@square_side) + column

            i < @square_side ** 2 or raise "Invalid i=#{i}"

            @file.seek(i * 2)
            bytes = @file.read(2)
            byte_1 = bytes[0].ord
            byte_2 = bytes[1].ord

            result = byte_1 * 256 + byte_2

            if result > 9000 || result < -9000
                # TODO(TK) try to detect the elevation from neighbour point:
                return nil
            end

            result
        end

        def square_side
            @square_side
        end
    end

    # EGM stands for "Earth Gravitational Model" and is a parser for the
    # EGM2008 file obtained from
    # http://earth-info.nga.mil/GandG/wgs84/gravitymod/egm2008/index.html
    class Undulations
        def initialize(dir_name=DIR_NAME)
            @file_name = GeoElevation::EGM2008_URL.split('/')[-1]
            @local_file_name = File.join(dir_name, @file_name.gsub(/.gz$/, ''))

            if !File.exist?(@local_file_name)
                puts "Downloading and ungzipping #{GeoElevation::EGM2008_URL}"
                GeoElevation::Utils::ungzip(open(GeoElevation::EGM2008_URL), @local_file_name)
            end

            # EGM files will not be loaded in memory because they are too big.
            # file.seek will be used to read values.

            file_size = File.size?(@local_file_name)

            lines = Math.sqrt(file_size / 2)
            puts "lines: #{lines}"
            lines == lines.to_i or raise "Invalid file size:#{file_size}"

            @rows = 180 * 24 * 2
            @columns = 360 * 24 + 2
            @file = open(@local_file_name)
        end

        def get_local_file_name()
             @local_file_name
        end

        def get_undulation(latitude, longitude)
            # TODO: Constants:
            la = -latitude + 90
            lo = longitude < 0 ? longitude + 360 : longitude
            row = (la * 24).floor
            column = (lo * 24).floor
            position = row * @columns + column

            #puts "#{latitude}, #{longitude} -> #{column}, #{row} -> #{position}"

            get_value_at_file_position(position)
        end

        # Loads a value from the n-th position in the EGM file. Every position
        # is a 4-byte real number.
        def get_value_at_file_position(position)
            @file.seek(4 + position * 4)
            bytes = @file.read(4)

            begin
                value = bytes[0].ord * 256**0 + bytes[1].ord * 256**1 + bytes[2].ord * 256**2 + bytes[3].ord * 256**3
                result = unpack(value)
            rescue
                result = 0
            end

            result
        end

        # Unpacks a number from the EGM file
        def unpack(n)
            sign = n >> 31
            exponent = (n >> (32 - 9)) & 0b11111111
            value = n & 0b11111111111111111111111

            result = nil
            if 1 <= exponent and exponent <= 254
                result = (-1)**sign * (1 + value * 2**(-23)) * 2**(exponent - 127)
            elsif exponent == 0
                result = (-1)**sign * value * 2**(-23) * 2**(-126)
            else
                # NaN, infinity...
                raise 'Invalid binary'
            end

            result.to_f
        end
    end

end
