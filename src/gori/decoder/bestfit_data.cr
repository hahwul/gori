module Gori::Decoder::BestFitData
  # The Unicode-published Microsoft WindowsBestFit tables, converted to
  # codepoint -> decoded target-codepage codepoint pairs. See bestfit/README.md
  # and bestfit/UNICODE-LICENSE.txt for source and license details.
  TABLES = {
     874 => {{ read_file("#{__DIR__}/bestfit/bestfit874.tsv") }},
     932 => {{ read_file("#{__DIR__}/bestfit/bestfit932.tsv") }},
     936 => {{ read_file("#{__DIR__}/bestfit/bestfit936.tsv") }},
     949 => {{ read_file("#{__DIR__}/bestfit/bestfit949.tsv") }},
     950 => {{ read_file("#{__DIR__}/bestfit/bestfit950.tsv") }},
    1250 => {{ read_file("#{__DIR__}/bestfit/bestfit1250.tsv") }},
    1251 => {{ read_file("#{__DIR__}/bestfit/bestfit1251.tsv") }},
    1252 => {{ read_file("#{__DIR__}/bestfit/bestfit1252.tsv") }},
    1253 => {{ read_file("#{__DIR__}/bestfit/bestfit1253.tsv") }},
    1254 => {{ read_file("#{__DIR__}/bestfit/bestfit1254.tsv") }},
    1255 => {{ read_file("#{__DIR__}/bestfit/bestfit1255.tsv") }},
    1256 => {{ read_file("#{__DIR__}/bestfit/bestfit1256.tsv") }},
    1257 => {{ read_file("#{__DIR__}/bestfit/bestfit1257.tsv") }},
    1258 => {{ read_file("#{__DIR__}/bestfit/bestfit1258.tsv") }},
  }
end
