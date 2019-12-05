module actual_rhs_module

  use burn_type_module

  implicit none

contains

  subroutine actual_rhs_init()

    implicit none

    ! Do nothing in this RHS.

  end subroutine actual_rhs_init



  subroutine actual_rhs(state, ydot)

    implicit none

    type (burn_t), intent(in) :: state
    double precision, intent(inout) :: ydot(neqs)

    ! Do nothing in this RHS.

    ydot = ZERO

  end subroutine actual_rhs



  subroutine actual_jac(state, jac)

    implicit none

    type (burn_t), intent(in) :: state
    double precision, intent(inout) :: jac(neqs, neqs)

    ! Do nothing in this RHS.

    state % jac(:,:) = ZERO

  end subroutine actual_jac

  subroutine update_unevolved_species(state)

    implicit none

    type (burn_t)    :: state

  end subroutine update_unevolved_species

end module actual_rhs_module
