# Monthly: a period-by-period spending overview. Bars compare income and spending for the last few
# weeks/months/quarters/years; the selected period shows income, spending by category and net
# income, and every row drills down into a bar chart for that category plus its transactions.
#
# All totals come from IncomeStatement (the same numbers the dashboard and reports use); the
# transaction lists come from Transaction::Search (the same filtering as the Transactions page).
class MonthlyController < ApplicationController
  INTERVALS = %w[week month quarter year].freeze
  KINDS = %w[income expense].freeze
  BAR_COUNT = 6
  TRANSACTION_LIMIT = 200

  before_action :set_periods

  def index
    @bars = @periods.map do |period|
      { period: period, income: total_money(:income, period), expense: total_money(:expense, period) }
    end

    @income = statement.income_totals(period: @selected)
    @expense = statement.expense_totals(period: @selected)
    @income_money = Money.new(@income.total, @income.currency)
    @expense_money = Money.new(@expense.total, @expense.currency)
    @net_money = @income_money - @expense_money
    @spending_categories = top_level_category_totals(@expense)
    @income_categories = top_level_category_totals(@income)

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("monthly.index.title"), nil ] ]
  end

  def breakdown
    @kind = KINDS.include?(params[:kind]) ? params[:kind] : "expense"
    @category = find_category(params[:category])

    @bars = @periods.map { |period| { period: period, total: breakdown_total(period) } }
    @selected_total = breakdown_total(@selected)

    @sort = params[:sort] == "largest" ? "largest" : "newest"
    @transactions = search.transactions_scope
                          .includes({ entry: :account }, :category, :merchant)
                          .reorder(Arel.sql(@sort == "largest" ? "ABS(entries.amount) DESC, entries.date DESC" : "entries.date DESC, entries.created_at DESC"))
                          .limit(TRANSACTION_LIMIT)

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("monthly.index.title"), monthly_path(interval: @interval, date: @selected.start_date) ], [ breakdown_title, nil ] ]
  end

  private
    helper_method :period_label, :period_title, :breakdown_title, :breakdown_path_for, :category_param

    def statement
      @statement ||= IncomeStatement.new(Current.family)
    end

    def set_periods
      @interval = INTERVALS.include?(params[:interval]) ? params[:interval] : "month"
      current_start = period_start(Date.current)

      selected_start = begin
        params[:date].present? ? period_start(Date.iso8601(params[:date])) : current_start
      rescue Date::Error
        current_start
      end
      selected_start = current_start if selected_start > current_start

      # The bars end at the current period, unless the selected one is further back than they reach.
      oldest_shown = advance(current_start, -(BAR_COUNT - 1))
      last_start = selected_start < oldest_shown ? selected_start : current_start

      @periods = (0...BAR_COUNT).to_a.reverse.map { |n| build_period(advance(last_start, -n)) }
      @selected = build_period(selected_start)
      @previous_start = advance(selected_start, -1)
      @next_start = selected_start < current_start ? advance(selected_start, 1) : nil
    end

    def period_start(date)
      case @interval
      when "week" then date.beginning_of_week
      when "quarter" then date.beginning_of_quarter
      when "year" then date.beginning_of_year
      else date.beginning_of_month
      end
    end

    def advance(start, count)
      case @interval
      when "week" then start + count.weeks
      when "quarter" then start + (count * 3).months
      when "year" then start + count.years
      else start + count.months
      end
    end

    def build_period(start)
      Period.custom(start_date: start, end_date: advance(start, 1) - 1.day)
    end

    def totals_for(kind, period)
      kind.to_s == "income" ? statement.income_totals(period: period) : statement.expense_totals(period: period)
    end

    def total_money(kind, period)
      totals = totals_for(kind, period)
      Money.new(totals.total, totals.currency)
    end

    # Parent categories already include their subcategories' amounts, so only top-level rows
    # (plus Uncategorized) are listed; subcategories are shown under their parent.
    def top_level_category_totals(period_total)
      period_total.category_totals
                  .reject { |ct| ct.category.subcategory? || ct.total.zero? }
                  .sort_by { |ct| -ct.total }
    end

    def find_category(value)
      return nil if value.blank?
      return Current.family.categories.uncategorized if value == Category::UNCATEGORIZED_FILTER_VALUE

      Current.family.categories.find(value)
    end

    def category_param(category)
      return nil if category.nil?

      category.uncategorized? ? Category::UNCATEGORIZED_FILTER_VALUE : category.id
    end

    def breakdown_total(period)
      totals = totals_for(@kind, period)
      amount = if @category.nil?
        totals.total
      else
        match = totals.category_totals.find do |ct|
          @category.uncategorized? ? ct.category.uncategorized? : ct.category.id == @category.id
        end
        match&.total || 0
      end
      Money.new(amount, totals.currency)
    end

    def search
      filters = {
        types: [ @kind ],
        status: [ "confirmed" ],
        start_date: @selected.start_date.iso8601,
        end_date: @selected.end_date.iso8601
      }
      if @category
        filters[:categories] = [ @category.uncategorized? ? Category::UNCATEGORIZED_FILTER_VALUE : @category.name ]
      end
      @search_filters = filters

      Transaction::Search.new(Current.family, filters: filters, accessible_account_ids: Current.user.accessible_accounts.pluck(:id))
    end

    def breakdown_title
      return @category.display_name if @category

      @kind == "income" ? t("monthly.index.income") : t("monthly.index.total_spend")
    end

    def breakdown_path_for(kind:, category: nil, date: @selected.start_date, sort: @sort)
      monthly_breakdown_path(interval: @interval, date: date, kind: kind, category: category_param(category), sort: (sort if sort == "largest"))
    end

    # Short label under a bar ("Nov", "Jul '25", "Nov 3", "Q4 '26", "2026").
    def period_label(period)
      start = period.start_date
      case @interval
      when "week" then start.strftime("%b %-d")
      when "quarter" then "Q#{((start.month - 1) / 3) + 1} '#{start.strftime('%y')}"
      when "year" then start.year.to_s
      else start.year == Date.current.year ? start.strftime("%b") : start.strftime("%b '%y")
      end
    end

    # Heading for the selected period ("November 2026", "Week of Nov 3", "Q4 2026", "2026").
    def period_title(period)
      start = period.start_date
      case @interval
      when "week" then t("monthly.index.week_of", date: start.strftime("%b %-d, %Y"))
      when "quarter" then "Q#{((start.month - 1) / 3) + 1} #{start.year}"
      when "year" then start.year.to_s
      else start.strftime("%B %Y")
      end
    end
end
