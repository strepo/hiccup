test "namespace current" {
  checkthat [namespace current] == "::"
  checkthat [namespace parent] == {}
}

test "namespace proc 1" {
  finalize { namespace temp } {
    namespace eval temp {
      proc one {} { return 1 }
      checkthat [namespace current] == "::temp"
      checkthat [namespace parent] == "::"
      checkthat [one] == 1
    }

    assertErr { one }

    assertNoErr { ::+ 4 5 }

    checkthat [temp::one] == 1
    checkthat [::temp::one] == 1
  }
}


test "nested ns" {
  namespace eval abc {
    namespace eval xyz {
      proc tada {} { return "yay!" }
    }
  }

  assertErr { tada }
  assertErr { abc::tada }
  assertErr { ::abc::tada }
  assertErr { ::xyz::tada }
  assertErr { xyz::tada }

  checkthat [abc::xyz::tada] eq "yay!"
  checkthat [::abc::xyz::tada] eq "yay!"
}

test "double ns" {
  finalize { ns abc2 } {
    namespace eval abc2::xyz2 {
        proc tada {} { return "yay!" }
    }
    checkthat [abc2::xyz2::tada] eq "yay!"
  }
}

test "namespace delete" {
  namespace eval foo {
    proc something {} { return 1 }
  }
  checkthat [namespace exists foo]
  namespace delete foo
  checkthat [not [namespace exists foo]]
}

test "ns variable scalar" {
  namespace eval hidden { variable IDS 4 }

  proc getit {} {
    variable ::hidden::IDS
    return $IDS
  }

 proc setit {} {
   variable ::hidden::IDS
   set IDS 11
 }

  checkthat [getit] == 4
  setit
  checkthat [getit] == 11

  finalize { proc setit proc getit namespace hidden }
}

test "ns variable array" {
  namespace eval foo {
    variable farr
    array set farr {
      1 one
      2 two
      3 three
    }

    checkthat $farr(1) eq one
  } 

  proc get_index ind {
    variable ::foo::farr 
    return $farr($ind)
  }
  
  checkthat [get_index 2] eq two
}

test "ns variable undefined scalar" {
  namespace eval hidden { variable IDS }

  proc getit {} {
    variable ::hidden::IDS
    return $IDS
  }

 proc setit {} {
   variable ::hidden::IDS
   set IDS 11
 }

  assertErr { getit }
  setit
  checkthat [getit] == 11

  finalize { proc setit proc getit namespace hidden }
}

test "ns proc variable" {
  namespace eval foo {
    variable boo 10
    proc doit {} {
      checkthat [not [info exists boo]]
      variable boo
      checkthat $boo == 10
      checkthat [info exists boo]
    }
    doit
  }

  finalize { namespace foo }
}

test "ns variable array 'array size'" {
  namespace eval foo {
    variable arr
    array set arr { 1 one 2 two 3 three }
  }

  checkthat [array size ::foo::arr] == 3
  finalize { namespace foo }
}

test "namespace tail" {
  checkthat [namespace tail boo] == boo
  checkthat [namespace tail ::oh::no] == no
  checkthat [namespace tail oh::no] == no
  checkthat [namespace tail ::] == {}
}

test "namespace qualifiers" {
  checkthat [namespace qualifiers boo] == {}
  checkthat [namespace qualifiers ::oh::no] == ::oh
  checkthat [namespace qualifiers oh::no] == oh
  checkthat [namespace qualifiers ::] == {}
}