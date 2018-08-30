local definitions = require('definitions')
local base64 = require('base64')
local utils = require('utils')

local function makestring(count, str)
   str = str or '0'
   return str:rep(count)
end

local function padLeft(str, padding)
   return makestring(math.max(0, padding)) .. str
end

local function padRight(str, padding) 
   return str .. makestring(math.max(0, padding))
end

local function reverse(t)
   local nt = {} -- new table
   local size = #t + 1
   for k,v in ipairs(t) do
      nt[size - k] = v
   end
   return nt
end

local function tobits(num)
   local t={}
   while num>0 do
      rest=num%2
      t[#t+1]=rest
      num=(num-rest)/2
   end
   t = reverse(t)
   return table.concat(t)
end

local function encodeIntToBits(number, numBits) 
   local bitString = ''

   if type(number) == 'number' then
      bitString = tobits(number)
   end

   -- Pad the str if not filling all bits
   if numBits >= bitString:len() then
      bitString = padLeft(bitString, numBits - bitString:len())
   end

   -- Truncate the str if longer than the number of bits
   if bitString:len() > numBits then
      bitString = bitString:sub(1, numBits)
   end

   return bitString
end

local function encodeBoolToBits(value)
   if value == true then
      return encodeIntToBits(1)
   end
   return encodeIntToBits(0)
end

local function encodeDateToBits(date, numBits)  -- date is deciseconds since epoch
   encodeIntToBits(date, numBits)
end

local function encodeLetterToBits(letter, numBits) 
   return encodeIntToBits(letter:upper():byte() - 65, numBits)
end

local function slice(table, first, last)
   local sliced = {}
   
   for i = first or 1, last or #tbl, step or 1 do
      sliced[#sliced+1] = tbl[i]
   end
   
   return sliced
end

local function encodeLanguageToBits(language, numBits)
   numBits = numBits or 12
   return encodeLetterToBits(language.slice(0, 1), numBits / 2)
      .. encodeLetterToBits(language.slice(1), numBits / 2)
end

local function decodeBitsToInt(bitString, start, length)
   start = start or 1
   length = length or 6
   local to_convert = bitString:sub(start, start + length - 1)
   local rval = tonumber(to_convert, 2)
   --utils.reveal(string.format("decodeBitsToInt:%s start:%s length:%s rval:%s", bitString, start, length, rval))
   return rval
end

local function decodeBitsToDate(bitString, start, length) 
   return decodeBitsToInt(bitString, start, length)
end

local function decodeBitsToBool(bitString, start) 
   return tonumber(bitString:sub(start, start), 2) == 1
end

local function decodeBitsToLetter(bitString) 
   local letterCode = decodeBitsToInt(bitString)
   --utils.reveal(string.format("bitString:%s letterCode:%s", bitString, letterCode))
   return string.lower(string.char(letterCode + 65))
end

local function decodeBitsToLanguage(bitString, start, length)
   --utils.reveal(string.format("decodeBitsToLanguage: string:%s start:%s length:%s", bitString, start, length))

   local languageBitString = bitString:sub(start, start + length - 1)
   
   --utils.reveal("languageBitString:"..utils.vardata(languageBitString))

   length = length or 0

   local str1 = languageBitString:sub(1, length / 2)
   local str2 = languageBitString:sub(length / 2 + 1)
   
   local rval1 = decodeBitsToLetter(str1)
   local rval2 = decodeBitsToLetter(str2)

   local rval = rval1..rval2
   
   --utils.reveal(string.format("decodeBitsToLanguage: %s", rval))
   return rval
end

local function encodeField(input_and_field)  -- { input, field } 
   local name, field_type, numBits, encoder, validator = unpack(input_field)

   if type(validator) == 'function' then
      if not validator(input) then
	 return ''
      end
   end
   
   if type(encoder) == 'function' then
      return encoder(input)
   end

   local bitCount = numBits
   if type(numBits) == 'function' then
      local bitCount = numBits(input)
   end
   
   local inputValue = input[name]
   
   local fieldValue = inputValue or ''
   
   if field_type == 'int' then
      return encodeIntToBits(fieldValue, bitCount)
   elseif field_type ==  'bool' then
      return encodeBoolToBits(fieldValue)
   elseif field_type == case 'date' then
      return encodeDateToBits(fieldValue, bitCount)
   elseif field_type == 'bits' then
      return padRight(fieldValue, bitCount - fieldValue.length):sub(1, bitCount - 1)
   elseif field_type == 'list' then
      return fieldValue.utils.reduce(function(acc, listValue)
	    acc = acc .. encodeFields({input = listValue, fields = field.fields })
	    return acc end, '')
   elseif field_type == 'language' then
      return encodeLanguageToBits(fieldValue, bitCount)
   else
      error(string.format('ConsentString - Unknown field type %s for encodeing', field_type))
   end
end

local function encodeFields(input_and_fields)
   local input, fields = unpack(input_and_fields)
   return fields.utils.reduce(function(acc, value)
	 acc = acc .. encodeField({input, field})
			      end, '')
end

local function decodeField(in_out_start_field)
   local input, output, startPosition, field =
      in_out_start_field.input,
   in_out_start_field.output,
   in_out_start_field.startPosition,
   in_out_start_field.field
   
   local datatype, numBits, decoder, validator, listCount =
      field.datatype, field.numBits, field.decoder, field.validator, field.listCount
   
   local bitCount = numBits
   if type(numBits) == 'function' then
      bitCount = numBits(output)
   end
   
   --utils.reveal(string.format("decodeField:%s", in_out_start_field.field.name))
   --utils.reveal(utils.as_string(in_out_start_field))
   --utils.reveal(string.format("field: %s", utils.as_string(field)))
   
   --utils.reveal(string.format("decodeField:%s type:%s numBits:%s decoder:%s validator:%s listCount:%s startPosition:%s input:%s", field.name, datatype, numBits, decoder, validator, listCount, startPosition, input:sub(startPosition, startPosition+bitCount-1))) BitCount-1 causes a problem if BitCount is nil
   
   if type(validator) == 'function' then
      if (not validator(output)) then
	 -- Not decoding this field so make sure we start parsing the
	 -- next field at the same point
	 return utils.see({ newPosition = startPosition })
      end
   end
   
   if type(decoder) == 'function' then
      local rval = decoder(input, output, startPosition)
      return utils.see(rval)
   end
   
   local bitCount = numBits
   if type(numBits) == 'function' then
      bitCount = numBits(output)
   end

   local listEntryCount = 0
   
   if type(listCount) == 'function' then
      listEntryCount = listCount(output)
   elseif type(listCount) == 'number' then
      listEntryCount = listCount
   end

   local switch_type = datatype

   if switch_type == 'int' then
      return utils.see({ fieldValue = decodeBitsToInt(input, startPosition, bitCount) })
   elseif switch_type == 'bool' then
      return utils.see({ fieldValue = decodeBitsToBool(input, startPosition) })
   elseif switch_type == 'date' then
      return utils.see({ fieldValue = decodeBitsToDate(input, startPosition, bitCount) })
   elseif switch_type == 'bits' then
      return utils.see({ fieldValue = input:sub(startPosition, startPosition + bitCount - 1) })
   elseif switch_type == 'language' then
      return utils.see({ fieldValue = decodeBitsToLanguage(input, startPosition, bitCount) })
   elseif switch_type == 'list' then
      local rval = {}
      for i = 1, listEntryCount do table.insert(rval, '') end
      utils.reduce(rval,
		   function(acc)
		      --utils.reveal("acc:"..utils.as_string(acc))
		      local decoded = decodeFields({
			    input = input,
			    fields = field.fields,
			    startPosition = acc.newPosition});
		      --utils.reveal("decoded:"..utils.as_string(decoded))
		      table.insert(acc.fieldValue, decoded.decodedObject)
		      local rval = {
			 fieldValue = acc.fieldValue,
			 newPosition = decoded.newPosition
		      }
		      utils.reveal(string.format("rval: %s=%s", field.name,utils.as_string(rval)))
		      return rval
		   end,
		   { fieldValue = {}, newPosition = startPosition })
      --utils.reveal("decodedList:"..utils.as_string(rval))
      return utils.see(rval)
   else
      error(string.format("ConsentString - Unknown field type:%s", switch_type))
   end
end

function decodeFields(input_fields_start)
   -- utils.reveal(string.format("decodeFields:%s", utils.as_string(input_fields_start)))
   
   local input, fields, startPosition = input_fields_start.input, input_fields_start.fields, input_fields_start.startPosition or 1;
   
   -- utils.reveal(string.format("decodeFields:%s", utils.as_string(input_fields_start)))

   local position = startPosition or 1

   -- utils.reveal(string.format("decodeField:%s", utils.as_string(fields)))
   local decodedObject = utils.reduce(
      fields, function(acc, field)
	 local name, numBits = field.name, field.numBits
	 --utils.reveal(string.format("acc1:%s %s", field.name, utils.as_string(field)))
	 local decode = {
	       input = input,
	       output = acc,
	       startPosition = position,
	       field = field
	 }
	 local decoded = decodeField(decode)
	 local fieldValue, newPosition = decoded.fieldValue, decoded.newPosition

	 --utils.reveal(string.format("decode:%s fieldValue:%s newPosition:%s",
	 --utils.as_string(decode), utils.as_string(fieldValue), newPosition))
	 
	 if fieldValue ~= nil then
	    acc[name] = fieldValue
	 end
	 
	 if newPosition then
	    position = newPosition
	 elseif type(numBits) == 'number' then
	    position = position + numBits
	 end
	 
	 --utils.reveal(string.format("acc2:%s %s", field.name, utils.as_string(acc)))
	 return acc
	      end, {})
   
   --utils.reveal("DecodeFields:"..utils.as_string(decodedObject))
   
   return { decodedObject = decodedObject, newPosition = position }
end

--[[*
   * Encode the data properties to a bit str. Encoding will encode
   * either `selectedVendorIds` or the `vendorRangeList` depending on
   * the value of the `isRange` flag.
--]]
local function encodeDataToBits(data, definitionMap) 
   local version = unpack(data)

   if type(version) ~= 'number' then
      error('ConsentString - No version field to encode')
   elseif not definitionMap[version] then
      error(string.format('ConsentString - No definition for version: %s', version))
   else
      local fields = definitionMap[version].fields
      return encodeFields({ input = data, fields })
   end
end

--[[*
   * Take all fields required to encode the consent str and produce the URL safe Base64 encoded value
--]]
local function encodeToBase64(data_definitionMap)
   data, definitionMap = unpack(data_definitionMap)

   definitionMap = definitionMap or definitions.vendorVersionMap
   
   local binaryValue = encodeDataToBits(data, definitionMap)

   if (binaryValue) then
      -- Pad length to multiple of 8
      local paddedBinaryValue = padRight(binaryValue, 7 - ((binaryValue:len() + 7) % 8))

      -- Encode to bytes
      local bytes = ''
      for i = 1, paddedBinaryValue:len(), 8 do
	 bytes = bytes .. String.char(tonumber(paddedBinaryValue:sub(i, 8 - 1), 2))
      end
   end

   -- Make base64 str URL friendly
   return base64.encode(bytes):gsub('%+', '-'):gsub('%/', '_'):gsub('=*$', '')
end

local function decodeConsentStringBitValue(bitString, definitionMap)
   definitionMap = definitionMap or definitions.vendorVersionMap

   --utils.reveal(utils.as_string(definitionMap))
   
   -- utils.reveal(string.format("bitString:%s definitions.versionNumBits:%s", bitString, definitions.versionNumBits))

   local version = decodeBitsToInt(bitString, 1, definitions.versionNumBits)

   -- utils.reveal(string.format("versionNumBits:%s version:%s",definitions.versionNumBits, version));
   
   if type(version) ~= 'number' then
      error('ConsentString - Unknown version number in the str to decode')
   elseif not definitions.vendorVersionMap[version] then
      error(string.format('ConsentString - Unsupported version %s in the str to decode', version))
   end

   local fields = definitionMap[version].fields
   local decodedObject = decodeFields({ input = bitString, fields = fields})

   --utils.reveal("DecodedObject:"..utils.as_string(decodedObject))

   return decodedObject
end

--[[*
   * Decode the (URL safe Base64) value of a consent str into an object.
--]]
local function decodeFromBase64(consentString, definitionMap) 
   -- Add padding
   local unsafe = consentString
   while unsafe:len() % 4 ~= 0 do
      unsafe = unsave .. '='
   end
   
   -- Replace safe characters
   unsafe = unsafe:gsub('-', '+'):gsub('_', '/')

   local bytes = base64.decode(unsafe)
   
   local inputBits = ''
   
   for i = 1, bytes:len(), 1 do
      local bitString = utils.tostringbase(bytes:byte(i), 2)
      inputBits = inputBits .. padLeft(bitString, 8 - bitString:len())
   end
   
   --utils.reveal("inputBits:"..inputBits)
   
   local rval = decodeConsentStringBitValue(inputBits, definitionMap)

   return rval
end

local function split(str, pattern)
   local rval = {}
   str:gsub('[^'..pattern..']', function(d) table.insert(rval, d) end)
   return rval
end

local function decodeBitsToIds(bitString)
   bitString = bitString or ""
   --utils.reveal("decodeBitsToIds:"..bitString)
   local rval = {}
   bitString:gsub('.', function(c) table.insert(rval, c) end)

   utils.reduce(rval, function(acc, value, index, rval) 
	 if value == '1' then
	    if acc.indexOf(index + 1) == -1 then
	       acc.push(index + 1)
	    end
	 end
	 return acc
		end, {})
   return rval
end

return {
   decodeFromBase64 = decodeFromBase64,
   decodeBitsToIds = decodeBitsToIds
}
