

puts "expr:"
puts [time { set x 0; while { expr { ($x + 1) < 15 * 20 + 5 } } { incr x } } 200]

puts "expr memo:"
set code { ($x + 1) < 15 * 20 + 5 } 
puts [time { set x 0; while { expr $code } { incr x } } 200]

puts "eval:"
puts [time { set x 0; while { eval { < [+ 1 $x]  [+ [* 15 20] 5] } } { incr x } } 200]

set x 11
puts "expr simple:"
puts [time { expr { $x <= 4 } } 20000]

puts "eval simple:"
puts [time { eval { <= $x 4 } } 20000]

exit

set z 0
while { bsexpr { $z < 100 } } {
  set y 0
  while { bsexpr { $y < 10 + (1 * 1 + 20 * 31 - 31 * 20) } } {
    set x 0; while { bsexpr { ($x + 1) < 10 * 20 + 5 } } { incr x } 
    incr y
  }
  incr z
}
exit

