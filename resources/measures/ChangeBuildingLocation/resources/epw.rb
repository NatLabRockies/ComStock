# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2018, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S) AND ANY CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER(S), ANY CONTRIBUTORS, THE
# UNITED STATES GOVERNMENT, OR THE UNITED STATES DEPARTMENT OF ENERGY, NOR ANY OF
# THEIR EMPLOYEES, BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

######################################################################
#  Copyright (c) 2008-2013, Alliance for Sustainable Energy.
#  All rights reserved.
#
#  This library is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public
#  License as published by the Free Software Foundation; either
#  version 2.1 of the License, or (at your option) any later version.
#
#  This library is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#  Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public
#  License along with this library; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
######################################################################

require 'csv'
# TODO: this should its own gem because this file may be useful in various workflows
module OpenStudio
  module Weather
    class Epw
      # access to all the weather data in array of arrays
      attr_accessor :filename, :data_type, :data_period, :weather_data
      attr_reader :city, :state, :country, :wmo, :lat, :lon, :gmt, :elevation, :header_data

      def initialize(filename)
        @filename = filename
        @city = ''
        @state = ''
        @country = ''
        @data_type = ''
        @wmo = ''
        @lat = ''
        @lon = ''
        @gmt = ''
        @elevation = ''
        @valid = false

        @header_data = []
        @weather_data = []
        process_header
      end

      def self.load(filename)
        raise "EPW file does not exist: #{filename}" unless File.file?(filename)

        f = OpenStudio::Weather::Epw.new(filename)
      end

      def to_kml(xml_builder_obj, url)
        xml_builder_obj.Placemark do
          xml_builder_obj.name @city
          xml_builder_obj.visibility '0'
          xml_builder_obj.description do
            xml_builder_obj.cdata!('<img src="kml/ep_header8.png" width=180 align=right><br><table><tr><td colspan="2">'\
                                   "<b>#{@city}</b></href></td></tr>\n" +
                                       # "<tr><td></td><td><b>Data Type</td></tr>\n"+
                                       "<tr><td></td><td>WMO <b>#{@wmo}</b></td></tr>\n" +
                                       # "<tr><td></td><td>E   3� 15'   N 36� 43'</td></tr>\n"+
                                       # "<tr><td></td><td><b>25</b> m</td></tr>\n"+
                                       "<tr><td></td><td>Time Zone GMT <b>#{@gmt}</b> hours</td></tr>\n" +
                                       # "<tr><td></td><td>ASHRAE Std 169 Climate Zone <b>4A - Mixed - Humid</b></td></tr>\n"+
                                       # "<tr><td></td><td>99% Heating DB=<b>3.1</b>, 1% Cooling DB=<b>33.2</b></td></tr>\n"+
                                       # "<tr><td></td><td>HDD18 <b>1019</b>, CDD10 <b>2849</b></td></tr>\n"+
                                       "<tr><td></td><td>URL #{url}</td></tr></table>")
          end
          xml_builder_obj.styleUrl '#weatherlocation'
          xml_builder_obj.Point do
            xml_builder_obj.altitudeMode 'absolute'
            xml_builder_obj.coordinates "#{@lon},#{@lat},#{elevation}"
          end
        end
      end

      def valid?
        return @valid
      end

      def save_as(filename)
        File.delete filename
        FileUtils.mkdir_p(File.dirname(filename))

        CSV.open(filename, 'wb') do |csv|
          @header_data.each { |r| csv << r }
          csv << [
            'DATA PERIODS', @data_period[:count], @data_period[:records_per_hour], @data_period[:name],
            @data_period[:start_day_of_week], @data_period[:start_date], @data_period[:end_date]
          ]
          @weather_data.each { |r| csv << r }
        end

        true
      end

      # Append the weather data (after data periods) to the end of the weather file. This allows
      # for the creation of multiyear weather files. Note that the date/order is not checked. It assumes
      # that the data are being added at the end is the more recent data
      #
      # @param filename [String] Path to the file that will be appended
      def append_weather_data(filename)
        to_append = OpenStudio::Weather::Epw.load(filename)

        prev_length = @weather_data.size
        @weather_data += to_append.weather_data

        prev_length + to_append.weather_data.size == @weather_data.size
      end

      def metadata_to_hash
        {
          city: @city,
          state: @state,
          country: @country,
          data_type: @data_type,
          wmo: @wmo,
          latitude: @lat,
          longitude: @lon,
          elevation: @elevation
        }
      end

      private

      # initialize
      def process_header
        header_section = true
        row_count = 0

        CSV.foreach(@filename, 'r') do |row|
          row_count += 1

          if header_section
            if row[0] =~ /data.periods/i
              @data_period = {
                count: row[1].to_i,
                records_per_hour: row[2].to_i,
                name: row[3],
                start_day_of_week: row[4],
                start_date: row[5],
                end_date: row[6]
              }

              header_section = false

              next
            else
              @header_data << row
            end
          else
            @weather_data << row
          end

          # process only header row
          # LOCATION,Adak Nas,AK,USA,TMY3,704540,51.88,-176.65,-10.0,5.0
          if row_count == 1
            @valid = true

            @city = row[1].tr('/', '-')
            @state = row[2]
            @country = row[3]
            @data_type = row[4]
            case @data_type
            when /TMY3/i
              @data_type = 'TMY3'
            when /TMY2/i
              @data_type = 'TMY2'
            when /TMY/i
              @data_type = 'TMY'
            end
            @wmo = row[5]
            @wmo.nil? ? @wmo = 'wmoundefined' : @wmo = @wmo.to_i
            @lat = row[6].to_f
            @lon = row[7].to_f
            @gmt = row[8].to_f
            @elevation = row[9].to_f
          end
        end
      end
    end
  end
end
