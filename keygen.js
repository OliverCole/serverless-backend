// Quick and dirty 32 byte key generator
// Probably not cryptographically safe
// Use in production at your own risk

const lowerCase = 'abcdefghijklmnopqrstuvwxyz';
const upperCase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const numbers = '1234567890';
const chars = lowerCase + upperCase + numbers;

let key = '';

for (let i = 0; i < 32; i++) {
     key += chars[Math.floor(Math.random() * chars.length)];
 }

console.log(key);
