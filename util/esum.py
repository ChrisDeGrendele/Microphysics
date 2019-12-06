import os
import re
import argparse



module_start = """
! NOTE: THIS FILE IS AUTOMATICALLY GENERATED
! DO NOT EDIT BY HAND

! Re-run esum.py to update this file

! Fortran 2003 implementation of the msum routine
! provided by Raymond Hettinger:
! https://code.activestate.com/recipes/393090/
! This routine calculates the sum of N numbers
! exactly to within double precision arithmetic.
!
! For perfomance reasons we implement a specialized
! version of esum for each possible value of N >= 3.
!
! Also for performance reasons, we explicitly unroll
! the outer loop of the msum method into groups of 3
! (and a group of 4 at the end, for even N). This seems
! to be significantly faster, but should still be exact
! to within the arithmetic because each one of the
! individual msums is (although this does not necessarily
! mean that the result is the same).
!
! This routine is called "esum" for generality
! because in principle we could add implementations
! other than msum that do exact arithmetic, without
! changing the interface as seen in the networks.

module esum_module

  use microphysics_type_module

  implicit none

  public

contains
"""



module_end = """
end module esum_module
"""



esum_template_start = """
  pure function esum@NUM@(array) result(esum)

    implicit none

    real(rt), intent(in) :: array(@NUM@)
    real(rt) :: esum
"""



esum_template_end = """
  end function esum@NUM@

"""



sum_template = """
    !$gpu

    esum = sum(array)
"""



kahan_template = """
    integer :: i
    real(rt) :: x, y, z

    !$gpu

    esum = array(1)
    x = ZERO
    do i = 2, @NUM@
       y = array(i) - x
       z = esum + y
       x = (z - esum) - y
       esum = z
    end do
"""



higher_precision_template = """
    real*16 :: higher_prec_array(@NUM@)

    !$gpu

    higher_prec_array(:) = array(:)

    esum = sum(higher_prec_array)
"""


msum_template_start = """
    ! Indices for tracking the partials array.
    ! j keeps track of how many entries in partials are actually used.
    ! The algorithm we model this off of, written in Python, simply
    ! deletes array entries at the end of every outer loop iteration.
    ! The Fortran equivalent to this might be to just zero them out,
    ! but this results in a huge performance hit given how often
    ! this routine is called during in a burn. So we opt instead to
    ! just track how many of the values are meaningful, which j does
    ! automatically, and ignore any data in the remaining slots.
    integer :: i, j, k, km

    ! Note that for performance reasons we are not
    ! initializing any unused values in this array.
    real(rt) :: partials(0:@NUMPARTIALS@)

    ! Some temporary variables for holding intermediate data.
    real(rt) :: x, y, z

    ! These temporary variables need to be explicitly
    ! constructed for the algorithm to make sense.
    ! If the compiler optimizes away the statement
    ! lo = y - (hi - x), the approach fails. This could
    ! be avoided with the volatile keyword, but at the
    ! expense of forcing additional memory usage
    ! which would slow down the calculation. Instead
    ! we will rely on the compiler not to optimize
    ! the statement away. This should be true for gcc
    ! by default but is not necessarily true for all
    ! compilers. In particular, Intel does not do this
    ! by default, so you must use the -assume-protect-parens
    ! flag for ifort.
    real(rt) :: hi, lo

    !$gpu

    ! The first partial is just the first term.
    esum = array(1)
"""

msum_template = """

    j = 0
    partials(0) = esum

    do i = 2, @NUM@

       km = j
       j = 0

       x = array(i+@START@)

       do k = 0, km
          y = partials(k)

          if (abs(x) < abs(y)) then
             ! Swap x, y
             z = y
             y = x
             x = z
          endif

          hi = x + y
          lo = y - (hi - x)

          if (lo .ne. 0.0_rt) then
             partials(j) = lo
             j = j + 1
          endif

          x = hi

       enddo

       partials(j) = x

    enddo

    esum = sum(partials(0:j))

"""



if __name__ == "__main__":

    sum_method = 0
    unroll = True

    parser = argparse.ArgumentParser()
    parser.add_argument('-s', help='summation method: -1 == sum(); 0 == msum; 1 == Kahan')
    parser.add_argument('--unroll', help='For msum, should we explicitly unroll the loop?')

    args = parser.parse_args()

    if args.s != None:
        sum_method = int(args.s)

    if args.unroll != None:
        if args.unroll == "True":
            unroll = True
        elif args.unroll == "False":
            unroll = False
        else:
            raise ValueError("--unroll can only be True or False.")

    with open("esum_module.F90", "w") as ef:

        ef.write(module_start)

        for num in range(3, 31):

            ef.write(esum_template_start.replace("@NUM@", str(num)))

            if sum_method == -1:

                # Fortran sum intrinsic

                ef.write(sum_template)

            elif sum_method == 0:

                # msum

                if unroll:

                    ef.write(msum_template_start.replace("@NUM@", str(num)).replace("@NUMPARTIALS@", str(4)))

                    i = 1
                    while (i < num):
                        if (i == num - 3):
                            if (i > 0):
                                offset = i-1
                            else:
                                offset = 0
                            ef.write(msum_template.replace("@START@", str(offset)).replace("@NUM@", str(4)))
                            break
                        else:
                            if (i > 0):
                                offset = i-1
                            else:
                                offset = 0
                            ef.write(msum_template.replace("@START@", str(offset)).replace("@NUM@", str(3)))
                            i += 2

                else:

                    ef.write(msum_template_start.replace("@NUM@", str(num)).replace("@NUMPARTIALS@", str(num-1)))

                    ef.write(msum_template.replace("@START@", str(0)).replace("@NUM@", str(num)))

            elif sum_method == 1:

                # Kahan

                ef.write(kahan_template.replace("@NUM@", str(num)))

            elif sum_method == 2:

                # Sum in 128-bit arithmetic

                ef.write(higher_precision_template.replace("@NUM@", str(num)))

            else:

                raise ValueError("Unknown summation method.")

            ef.write(esum_template_end.replace("@NUM@", str(num)))
            ef.write("\n")

        ef.write(module_end)
