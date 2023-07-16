require 'chunky_png'

require_relative 'geoelevation'
require 'bigdecimal'
require 'bigdecimal/util'

module GeoElevation

    def self.elevation_image(width, height, latitude_interval, longitude_interval, max_elevation)
        #(latitude_interval and latitude_interval.length == 0) or raise "Invalid latitude_interval: #{latitude_interval}"
        srtm = GeoElevation::Srtm.new
        image = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::BLACK)
        for x in 0...height
            for y in 0...width
                latitude = latitude_interval[0] + (x / width.to_f) * (latitude_interval[1] - latitude_interval[0])
                longitude = longitude_interval[0] + (y / height.to_f) * (longitude_interval[1] - longitude_interval[0])
                elevation = srtm.get_elevation(latitude, longitude)

                #puts "(#{x}, #{y}) -> (#{latitude}, #{longitude}) #{elevation}, #{max_elevation}, #{elevation/max_elevation.to_f}"

                if elevation == nil
                    pixel = ChunkyPNG::Color.rgb 255, 255, 255
                elsif elevation == 0
                    pixel = ChunkyPNG::Color.rgb 0, 0, 255
                else
                    elevation_ratio = elevation / max_elevation.to_d
                    if elevation_ratio > 1.0
                        elevation_ratio = 1.0
                    end
                    pixel = ChunkyPNG::Color.rgb 0, (elevation_ratio * 255).to_i, 0
                end

                #puts "[#{x}/#{height}, #{y}/#{width}]"
                image[y, width - x - 1] = pixel
            end
        end
        image
    end

    # Return RMagick image with undulations. In black are the positive 
    # values in white the negative. Used for debugging.
    def self.world_undulation_image(width, height)
        egm = GeoElevation::Undulations.new
        min, max = 0, 0

        ondulations = []
        (0...height).each do |h|
            latitude = -(h / height.to_f) * 180 + 90
            (0...width).each do |w|
                longitude = (w / width.to_f) * 360 - 180
                value = egm.get_undulation(latitude, longitude)
                #puts "#{w}, #{h} -> #{latitude}, #{longitude} -> #{value}"
                min = [value, min].min
                max = [value, max].max
                #puts "value=#{value}, min=#{min}, max=#{max}"
                ondulations << [w, h, value]
            end
        end

        # min -106.73819732666016 => -13
        # max   85.15642547607422 => 241
        value_range = (max - min).abs
        image = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::BLACK)
        ondulations.each do |ondulation|
            w, h, value = ondulation
            if value < 0
                color_value = (value.abs / min.abs.to_f) * 128 + 128
            end
            if value > 0
                color_value = ((value.abs / max.abs.to_f) * 128 - 128) * -1
            end
            if value == 0
                color_value = 128
            end
            color_value = color_value.to_i
            #color_value = ((((value + min.abs) / value_range.to_f * 255).to_i) - 255) * -1
            #puts "#{value} #{color_value}"
            pixel = ChunkyPNG::Color.rgb(color_value, color_value, color_value)
            image[w,h] = pixel
        end

        image
    end

end
