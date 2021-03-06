crypto = require 'crypto'
stream = require 'stream'
message = require './message'
opse = require './opse'

# Largely a passthrough stream.  It won't change the data, but it will do some 
# trivial index generation and keep track of the size of the data passed to it.
# Access Indexer.index to get the properly formed index for the given data, and
# Indexer.size for the size in bytes of the given data.
#
# 1. `id` is the id of the document being indexed.  Document ids should have no
#    publicly discernable relationship to the document.  Random ids are
#    recommended (but not required).  Auto generated ids like from Twitter's 
#    Snowflake or RethinkDB are fine to use.  *(Object)*
class exports.Indexer extends stream.Transform
    constructor: (@id) ->
        if not this instanceof exports.Indexer
            return new exports.Indexer @id
        
        stream.Transform.call this, decodeStrings: true
        [@index, @leftover, @size] = [{id: @id, list: {}}, '', 0]
    
    _clean: (word) -> word.toLowerCase().replace /[^a-z0-9]/g, ''
    _push: (data) ->
        data[i] = @_clean word for i, word of data
        for word in data
            if @index.list[word]? then ++@index.list[word]
            else @index.list[word] = 1
        
        delete @index['']
    
    _transform: (chunk, encoding, done) ->
        data = (@leftover + chunk.toString()).split /[\s]/g
        @leftover = data.splice(data.length - 1, 1)?[0]
        @_push data
        @size += chunk.length
        
        @push chunk
        done()
    
    _flush: (done) ->
        if @leftover.length is 0 then return done()
        @_push [@leftover]
        @push null
        done()


# Utility class for a secure single-user search server.
#
# **Note:**  The server utility doesn't offer any user authentication.
#     Authenticating file/index uploads is strongly recommended (for the obvious
#     reason), but will have to be done by the developer.  Searches and
#     and downloads do not require authentication, but it doesn't hurt.
#
# 1. `index` is the secure index to initialize the server.  Use {} if none.  To
#    persist the secure index, before the application is shut down access
#    Server.index and save the object in a persistent data store.  *(Object)*
class exports.Server
    constructor: (@index) ->
        if not this instanceof exports.Server
            return new exports.Server @index
    
    # Takes a secure query and returns an array of matching document ids.
    #
    # 1. `query` a secure query generated by the client.  *(Object)*
    search: (query) ->
        out = []
        for dn, trpdrs of query
            if not @index[dn]? then return
            domain = @index[dn].index
            
            good = (entry) -> entry? and -1 is out.indexOf entry
            out.push domain[trpdr] for trpdr in trpdrs when good domain[trpdr]
        
        out.sort (a, b) -> b[1] - a[1]
    
    # Attempts to update the secure index.  Will either return true, indicating
    # that the update was successful or a merge request telling the client to 
    # merge it's current index with the given index and retry.
    #
    # 1. `domain` is the index domain name.  Domain names should have no
    #    publicly discernable relationship to the data under them.  It is
    #    recommended (but not required) that they be random.  Cannont take the
    #    value `sorting`.  *(String)*
    # 2. `index` the new secure index supplied by the client.  *(Object)*
    # 3. `reps` is the list old domains that this new request will replace.
    #    *(Array)*
    update: (domain, index, reps = []) ->
        for dn, cand of @index
            if cand.docs.length <= index.docs.length and reps.indexOf(dn) is -1
                return [dn, cand.docs]
        
        delete @index[dn] for dn in reps
        @index[domain] = index
        
        true


# Utility class for a secure multi-user search server.
#
# **Note:**  Same recommendations on authentication as above.  However, the
#     server's state *is* authenticated, and will throw an error if auth fails.
#
# **Note:**  This utility doesn't provide anywhere to store things like packed
#     keys, even though providing such a place is recommended.  It should be
#     observed that even though the server isn't allowed to decrypt packed keys
#     and the like, they are signed by document owners and can be verified by
#     the server nevertheless.
#
# 1. `state` is the state provided by the client.  *(Buffer)*
# 2. `index` is the secure index to initialize the server...  *(See above.)*
# 3. `keychain` follows the same format as `caesar.message.Encrypter.keys`.  The
#    server's private key should be in the `private` section of the object
#    (under the name `server`).  The public key(s) of the document 
#    owner(s) should be in the `public` section.  *(Object)*
class exports.MultiUserServer extends exports.Server
    constructor: (state, @index, @keychain) ->
        if not this instanceof exports.MultiUserServer
            return new exports.MultiUserServer state, @index, @keychain
        
        if state isnt null then @state state
    
    # Sets the state of the server.
    #
    # 1. `state` is the provided state.  *(Buffer)*
    state: (state) ->
        decrypter = new message.Decrypter @keychain, true, 'asym'
        decrypter.write state
        @stateKey = decrypter.read()
    
    # *(See above.)*
    search: (query) ->
        for domain, trpdrs of query # Decrypt query.
            for i, trpdr of trpdrs
                decipher = crypto.createDecipher 'aes-256-ctr', @stateKey
                decipher.write trpdr, 'base64'
                query[domain][i] = decipher.read().toString 'base64'
        
        super query


# Utility class for a secure single-user search client.
#
# 1. `keys` is the keyring used to maintain the secure index.  The initial value
#    should be in the form `{sorting: caesar.key.createRandom()}`.
#    To persist the key ring, before the application is shut down access
#    Client.keys and save the object in a persistent data store.  *(Object)*
class exports.Client
    constructor: (@keys) ->
        if not this instanceof exports.Client
            return new exports.Client @keys
    
    # Deletes the information on domains that have been outdated.
    #
    # 1. `dn` is a domain name to delete.  *(String)*
    # 2. ...
    outdate: (dns...) -> delete @keys[dn] for dn in dns
    
    # Creates a secure query on a given word.
    #
    # 1. `word` the word to generate the query on.  *(String)*
    createQuery: (word) ->
        word = word.substr 0, 28
        offset = 28 - word.length
        
        out = {}
        for dn, key of @keys when dn isnt 'sorting'
            out[dn] = []
            i = 0
            
            until i is key[0]
                buff = new Buffer 32
                buff.fill 0
                buff.writeUInt32BE i, 28
                buff.write word, offset, word.length
                
                hash = crypto.createHash 'sha256'
                hash.end buff
                sum = hash.read()
                
                cipher = crypto.createCipher 'aes-256-cbc', key[1]
                cipher.write sum
                
                k = cipher.read().toString 'base64'
                out[dn].push k
                ++i
        
        out
    
    # Creates a secure index.
    #
    # 1. `domain` is the domain name of the index.  See Server.update for more
    #    information on domain names.  *(String)*
    # 2. `max` is the size in bytes of the largest document included in the
    #    given index.  *(Number)*
    # 3. `index` is an index to secure.  (From Indexer or the like).  *(Object)*
    # 4. ...
    secureIndex: (domain, max, indexes...) ->
        key = crypto.randomBytes 32
        index = {} # Merge indexes.
        
        for list in indexes
            for word, count of list.list
                if index[word]? then index[word].push [list.id, count]
                else index[word] = [[list.id, count]] 
        
        sindex = {} # Secure index
        for word, entries of index
            word = word.substr 0, 28
            offset = 28 - word.length
            
            for n, entry of entries
                buff = new Buffer 32
                buff.fill 0
                buff.writeUInt32BE n, 28
                buff.write word, offset, word.length
                
                hash = crypto.createHash 'sha256'
                hash.end buff
                sum = hash.read()
                
                cipher = crypto.createCipher 'aes-256-cbc', key
                cipher.write sum
                
                k = cipher.read().toString 'base64'
                
                entry[1] = opse.encrypt @keys.sorting, entry[1]
                sindex[k] = entry
        
        words = Object.keys index # Get an array of the unique words.
        docs = [] # Get an array of unique document ids
        for word, entries of index
            docs.push ent[0] for ent in entries when -1 is docs.indexOf ent[0]
        
        @keys[domain] = [docs.length, key] # Key management.
        
        one = [256, 131072, 50331648] # Pad the secure index.
        two = [256, 65536, 16777216]
        [threshold, sum, i] = [0, 0, 0]
        
        while threshold <= max
            threshold += one[i]
            sum += two[i]
            ++i
        
        threshold = threshold - one[i - 1]
        sum = sum - two[i - 1]
        sum += Math.floor((max - threshold) / i)
        
        for id in docs
            c = 0 # Number of entries in the index that already contain id.
            ++c for entry in sindex when entry is id
            
            l = sum - c
            while l -= 1
                buff = new Buffer 32
                buff.fill 0
                buff.writeUInt32BE docs.length + l, 28
                
                hash = crypto.createHash 'sha256'
                hash.end buff
                sum = hash.read()
                
                cipher = crypto.createCipher 'aes-256-cbc', key
                cipher.write sum
                cipher.end '00000000', 'hex'
                data = cipher.read()
                
                k = data.slice(0, 32).toString 'base64'
                n = data.slice(32).readUInt32BE(0) % 131072
                
                sindex[k] = [id, n]
        
        shuffle = (array) ->
            i = array.length
            if i is 0 then return false
            
            bytes = Math.ceil(Math.log(array.length) / (8 * Math.log(2)))
            while i -= 1
                j = array.length # Guess random numbers until one is in range.
                until j < array.length
                    a = new Buffer 4 # Create new blank buffer.
                    a.fill 0
                    
                    b = crypto.randomBytes bytes # Write random 32bit uint.
                    b.copy a
                    
                    j = a.readUInt32LE(0) # Read as 32bit uint.
                
                [array[j], array[i]] = [array[i], array[j]] # Swap values.
            
            array
        
        keys = shuffle Object.keys sindex # Shuffle the secure index.
        rsindex = {}
        rsindex[key] = sindex[key] for key in keys
        
        docs: docs, index: rsindex


# Utility class for a secure multi-user search client.
#
# 1. `keys` is the keyring used to maintain the secure index.  *(See above.)*
# 2. `keychain` follows the same format as `caesar.message.Encrypter.keys`.  The
#    current user's private key should be in the `private` section of this
#    object.  The document owner(s) should have their own, the server's, and all
#    authenticated users' public keys in the `public` section.  Other users only
#    need to have the document owner(s)' public key(s) in the `public` section.
#    *(Object)*
class exports.MultiUserClient extends exports.Client
    constructor: (@keys, @keychain = {}) ->
        if not this instanceof exports.MultiUserClient
            return new exports.MultiUserClient @keys, @keychain
    
    # Calculates a state for the server.  Only document owners can call this
    # function.  This function's output authenticates user queries on the
    # server, and should be used to add/revoke user access by adding/removing
    # them from your keychain.
    state: ->
        key = crypto.randomBytes 32
        encrypter = new message.Encrypter @keychain, true, 'asym'
        encrypter.write key
        
        encrypter.read()
    
    # Packs the keys used to manage the secure index so that they can be posted
    # publicly and unpacked by other authorized users.  Only document owners can
    # call this function.
    packKeys: ->
        out = {}
        
        server = @keychain.server
        delete @keychain.server
        
        encrypter = new message.Encrypter @keychain, true, 'asym'
        encrypter.write new Buffer JSON.stringify @keys
        
        @keychain.server = server
        encrypter.read()
    
    # Unpacks the keys used to manage the secure index.  Any user can call this
    # function.
    #
    # 1. `packed` is the encrypted keychain to unpack.  *(Buffer)*
    unpackKeys: (packed) ->
        server = @keychain.server
        delete @keychain.server
        
        decrypter = new message.Decrypter @keychain, true, 'asym'
        decrypter.write packed
        out = JSON.parse decrypter.read()
        
        @keys[dn] = [key[0], new Buffer(key[1])] for dn, key of out
        @keychain.server = server
    
    # Creates a secure query on a given word.  Any user can call this function.
    #
    # 1. `state` is the current server state.  *(Buffer)*
    # 2. `word` the word to generate the query on... *(See above.)*
    createQuery: (state, word) ->
        decrypter = new message.Decrypter @keychain, true, 'asym'
        decrypter.write state
        key = decrypter.read() # Decrypt state to get the key.
        
        query = super word
        
        for domain, trpdrs of query # Encrypt query.
            for i, trpdr of trpdrs
                cipher = crypto.createCipher 'aes-256-ctr', key
                cipher.write trpdr, 'base64'
                query[domain][i] = cipher.read().toString 'base64'
        
        query
