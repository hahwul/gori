# Test String.new() behavior with invalid UTF-8
invalid_bytes = Bytes[0xFF, 0xFE, 0x41] # Invalid UTF-8 sequence + valid 'A'
str = String.new(invalid_bytes)
puts "Created string: #{str.inspect}"
puts "Valid encoding? #{str.valid_encoding?}"
puts "Bytes: #{str.bytes.inspect}"
