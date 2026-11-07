require "test_helper"

class MonthlyControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    Entry.where(account: @family.accounts).destroy_all
  end

  test "overview shows the selected month's income, spending by category and net income" do
    month = Date.current.beginning_of_month
    create_transaction(name: "Paycheck", amount: -2000, date: month + 1.day, category: categories(:income))
    create_transaction(name: "Groceries", amount: 150, date: month + 2.days, category: categories(:food_and_drink))
    create_transaction(name: "Last month", amount: 999, date: month - 5.days, category: categories(:food_and_drink))

    get monthly_path

    assert_response :success
    assert_select "h2", text: month.strftime("%B %Y")
    assert_includes response.body, "$2,000.00"
    assert_includes response.body, "$150.00"
    assert_includes response.body, "$1,850.00"
    assert_includes response.body, ERB::Util.html_escape(categories(:food_and_drink).name)
  end

  test "every interval renders, and a future or invalid date falls back to the current period" do
    MonthlyController::INTERVALS.each do |interval|
      get monthly_path(interval: interval)
      assert_response :success
    end

    get monthly_path(date: 2.years.from_now.to_date.iso8601)
    assert_select "h2", text: Date.current.strftime("%B %Y")

    get monthly_path(date: "not-a-date")
    assert_response :success
  end

  test "selecting an older month shows that month" do
    old_month = 10.months.ago.to_date.beginning_of_month
    create_transaction(name: "Old groceries", amount: 42, date: old_month + 3.days, category: categories(:food_and_drink))

    get monthly_path(date: old_month.iso8601)

    assert_select "h2", text: old_month.strftime("%B %Y")
    assert_includes response.body, "$42.00"
  end

  test "category breakdown lists only that category's transactions in the selected month" do
    month = Date.current.beginning_of_month
    create_transaction(name: "Grocery store", amount: 80, date: month, category: categories(:food_and_drink))
    create_transaction(name: "Paycheck", amount: -500, date: month, category: categories(:income))
    create_transaction(name: "Previous month groceries", amount: 30, date: month - 1.day, category: categories(:food_and_drink))

    get monthly_breakdown_path(kind: "expense", category: categories(:food_and_drink).id)

    assert_response :success
    assert_includes response.body, "Grocery store"
    assert_not_includes response.body, "Paycheck"
    assert_not_includes response.body, "Previous month groceries"
  end

  test "income breakdown and uncategorized breakdown render" do
    create_transaction(name: "Side gig", amount: -75, date: Date.current)
    create_transaction(name: "Mystery charge", amount: 12, date: Date.current)

    get monthly_breakdown_path(kind: "income")
    assert_response :success
    assert_includes response.body, "Side gig"

    get monthly_breakdown_path(kind: "expense", category: Category::UNCATEGORIZED_FILTER_VALUE, sort: "largest")
    assert_response :success
    assert_includes response.body, "Mystery charge"
    assert_not_includes response.body, "Side gig"
  end

  test "another family's category cannot be opened" do
    other = Category.create!(family: families(:empty), name: "Not mine", color: "#000000")

    get monthly_breakdown_path(kind: "expense", category: other.id)

    assert_response :not_found
  end
end
