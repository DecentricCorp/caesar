// Generated by CoffeeScript 1.7.1
(function() {
  var crypto;

  crypto = require('crypto');

  exports.chain = function(value, n, alg) {
    var sum, _ref;
    if (n == null) {
      n = 1;
    }
    if (alg == null) {
      alg = 'sha512';
    }
    sum = function(val) {
      var hash;
      hash = crypto.createHash(alg);
      hash.end(val);
      return hash.read();
    };
    while (n !== 0) {
      _ref = [n - 1, sum(value)], n = _ref[0], value = _ref[1];
    }
    return value;
  };

}).call(this);
